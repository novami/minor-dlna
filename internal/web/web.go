// Package web serves the local management UI: first-run setup and settings.
package web

import (
	"context"
	"embed"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"log/slog"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/novami/minor-dlna/internal/config"
	"github.com/novami/minor-dlna/internal/dlna"
	"github.com/novami/minor-dlna/internal/library"
	"github.com/novami/minor-dlna/internal/macos"
	"github.com/novami/minor-dlna/internal/metadata"
	"github.com/novami/minor-dlna/internal/renderer"
	"github.com/novami/minor-dlna/internal/transcode"
	"github.com/novami/minor-dlna/internal/update"
	"golang.org/x/crypto/bcrypt"
)

//go:embed static
var staticFS embed.FS

type Server struct {
	Cfg       *config.Config
	CfgPath   string
	Cat       *library.Catalog
	Scanner   *library.Scanner
	Version   string
	FFmpeg    bool
	Updates   *update.Manager
	Meta      *metadata.Service
	TV        *renderer.Controller
	Transcode *transcode.Service
	HLS       *transcode.HLS
	Profiles  *transcode.Resolver
	Restart   func() // apply a saved config
	Quit      func()
}

func (s *Server) Register(mux *http.ServeMux) {
	static, _ := fs.Sub(staticFS, "static")
	mux.Handle("GET /{$}", s.public(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		http.ServeFileFS(w, r, static, "index.html")
	})))
	// Embedded files have no modification time; without no-cache a browser keeps the old UI after an update.
	files := http.StripPrefix("/static/", http.FileServerFS(static))
	mux.Handle("GET /static/", s.public(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-cache")
		files.ServeHTTP(w, r)
	})))
	mux.Handle("POST /api/login", s.public(http.HandlerFunc(s.login)))
	mux.Handle("POST /api/logout", s.public(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		sessions.drop(w, r)
		writeJSON(w, map[string]bool{"ok": true})
	})))
	mux.Handle("GET /api/ping", s.local(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Write([]byte("minordlna"))
	})))
	mux.Handle("GET /api/state", s.local(http.HandlerFunc(s.state)))
	mux.Handle("POST /api/config", s.local(http.HandlerFunc(s.saveConfig)))
	mux.Handle("POST /api/pick-folder", s.local(http.HandlerFunc(s.pickFolder)))
	mux.Handle("POST /api/rescan", s.local(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		s.Scanner.Rescan()
		writeJSON(w, map[string]bool{"ok": true})
	})))
	mux.Handle("GET /api/storage", s.local(http.HandlerFunc(s.storage)))
	mux.Handle("POST /api/storage/clean", s.local(http.HandlerFunc(s.cleanStorage)))
	mux.Handle("GET /api/browse", s.local(http.HandlerFunc(s.browse)))
	mux.Handle("GET /api/meta", s.local(http.HandlerFunc(s.metaList)))
	mux.Handle("GET /api/meta/search", s.local(http.HandlerFunc(s.metaSearch)))
	mux.Handle("POST /api/meta/set", s.local(http.HandlerFunc(s.metaSet)))
	s.registerTV(mux)
	s.registerClients(mux)
	s.registerPlayer(mux)
	mux.Handle("GET /api/update", s.local(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, s.Updates.State())
	})))
	mux.Handle("POST /api/update/check", s.local(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = s.Updates.Check(r.Context())
		writeJSON(w, s.Updates.State())
	})))
	mux.Handle("POST /api/update/install", s.local(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		// Runs detached: the request would otherwise be cancelled by the restart into the new version.
		go func() { _ = s.Updates.Install(context.Background()) }()
		writeJSON(w, map[string]bool{"started": true})
	})))
	mux.Handle("POST /api/quit", s.local(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, map[string]bool{"ok": true})
		go func() { time.Sleep(300 * time.Millisecond); s.Quit() }()
	})))
}

// local restricts management to this Mac and blocks cross-site requests:
// the client must be loopback, the Host must be a loopback name (defeats DNS rebinding),
// and state-changing requests need a custom header that browsers only send from our own page.
//
// Other devices get in only when remote access is enabled and they hold a session from /api/login.
// The session cookie is SameSite=Strict and host-only, so a rebinding or foreign site never carries it.
func (s *Server) local(next http.Handler) http.Handler {
	return s.guard(next, false)
}

// public lets unauthenticated remote clients load the page shell, so it can show the login form.
func (s *Server) public(next http.Handler) http.Handler {
	return s.guard(next, true)
}

func (s *Server) guard(next http.Handler, public bool) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet && r.Header.Get("X-MinorDLNA") != "1" {
			http.Error(w, "forbidden", http.StatusForbidden)
			return
		}
		if isLocal(r) {
			next.ServeHTTP(w, r)
			return
		}
		if !s.remoteEnabled() {
			http.Error(w, "Správa je dostupná jen na Macu se serverem: http://localhost:"+portOf(r), http.StatusForbidden)
			return
		}
		if public || sessions.valid(r) {
			next.ServeHTTP(w, r)
			return
		}
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		w.WriteHeader(http.StatusUnauthorized)
		_ = json.NewEncoder(w).Encode(map[string]string{"error": "login"})
	})
}

// isLocal: loopback client and loopback Host header (defeats DNS rebinding).
func isLocal(r *http.Request) bool {
	host, _, _ := net.SplitHostPort(r.RemoteAddr)
	ip := net.ParseIP(host)
	reqHost := r.Host
	if h, _, err := net.SplitHostPort(r.Host); err == nil {
		reqHost = h
	}
	return ip != nil && ip.IsLoopback() && (reqHost == "localhost" || reqHost == "127.0.0.1" || reqHost == "::1")
}

func (s *Server) remoteEnabled() bool {
	return s.Cfg.Remote.Enabled && s.Cfg.Remote.PasswordHash != ""
}

func portOf(r *http.Request) string {
	if _, p, err := net.SplitHostPort(r.Host); err == nil {
		return p
	}
	return "8200"
}

type libraryJSON struct {
	Name  string             `json:"name"`
	Type  config.LibraryType `json:"type"`
	Paths []string           `json:"paths"`
	Count int                `json:"count"`
}

type stateJSON struct {
	Version      string           `json:"version"`
	Name         string           `json:"name"`
	ComputerName string           `json:"computer_name"`
	SetupNeeded  bool             `json:"setup_needed"`
	Autostart    bool             `json:"autostart"`
	FFmpeg       bool             `json:"ffmpeg"`
	Scanning     bool             `json:"scanning"`
	Progress     library.Progress `json:"progress"`
	Addresses    []string         `json:"addresses"`
	Libraries    []libraryJSON    `json:"libraries"`
	DTS          bool             `json:"dts"`
	IsLocal      bool             `json:"is_local"`
	Remote       bool             `json:"remote"`
	AutoUpdate   bool             `json:"auto_update"`
	MenuBar      bool             `json:"menubar"`
	InApp        bool             `json:"in_app"`
	Metadata     bool             `json:"metadata"`
	TMDb         bool             `json:"tmdb"`
	HWAccel      string           `json:"hwaccel"`
	Suggestions  []libraryJSON    `json:"suggestions"`
	Home         string           `json:"home"`
}

func (s *Server) state(w http.ResponseWriter, r *http.Request) {
	counts := s.Cat.Counts(r.Context())
	libs := []libraryJSON{}
	for i, l := range s.Cfg.Libraries {
		lj := libraryJSON{Name: l.Name, Type: l.Type, Paths: l.Paths}
		if i < len(s.Cat.Libraries()) {
			lj.Count = counts[s.Cat.Libraries()[i].ID]
		}
		libs = append(libs, lj)
	}
	writeJSON(w, stateJSON{
		Version: s.Version, Name: s.Cfg.Name, ComputerName: macos.ComputerName(),
		SetupNeeded: len(s.Cfg.Libraries) == 0, Autostart: macos.AutostartEnabled(),
		FFmpeg: s.FFmpeg, Scanning: s.Scanner.Scanning(), Progress: s.Scanner.Progress(), Addresses: lanAddresses(s.Cfg.Port),
		Libraries: libs, IsLocal: isLocal(r), Remote: s.remoteEnabled(), DTS: s.Cfg.Transcode.DTSEnabled(), AutoUpdate: s.Cfg.Updates.AutoEnabled(), HWAccel: s.Cfg.Transcode.HWAccel,
		Suggestions: suggestions(), Home: homeDir(), MenuBar: s.Cfg.MenuBarEnabled(), InApp: inApp(),
		Metadata: s.Cfg.Metadata.On(), TMDb: s.Cfg.Metadata.TMDbToken != "",
	})
}

func inApp() bool {
	_, ok := macos.AppBundle()
	return ok
}

// suggestions offers the standard macOS media folders that exist and are not empty.
func suggestions() []libraryJSON {
	home, err := os.UserHomeDir()
	if err != nil {
		return nil
	}
	var out []libraryJSON
	for _, c := range []libraryJSON{
		{Name: "Filmy", Type: config.Movies, Paths: []string{filepath.Join(home, "Movies")}},
		{Name: "Fotky", Type: config.Photos, Paths: []string{filepath.Join(home, "Pictures")}},
		{Name: "Hudba", Type: config.Music, Paths: []string{filepath.Join(home, "Music")}},
	} {
		if entries, err := os.ReadDir(c.Paths[0]); err == nil && len(entries) > 0 {
			out = append(out, c)
		}
	}
	return out
}

type configRequest struct {
	Name      string `json:"name"`
	Libraries []struct {
		Name  string             `json:"name"`
		Type  config.LibraryType `json:"type"`
		Paths []string           `json:"paths"`
	} `json:"libraries"`
	DTS        bool    `json:"dts"`
	HWAccel    string  `json:"hwaccel"`
	Autostart  bool    `json:"autostart"`
	AutoUpdate *bool   `json:"auto_update"`
	Remote     *bool   `json:"remote"`
	MenuBar    *bool   `json:"menubar"`
	Metadata   *bool   `json:"metadata"`
	TMDbToken  *string `json:"tmdb_token"` // nil = keep, "" = remove
	Password   string  `json:"password"`   // new password for remote access, empty = keep
}

func (s *Server) saveConfig(w http.ResponseWriter, r *http.Request) {
	var req configRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20)).Decode(&req); err != nil {
		writeError(w, "Neplatný požadavek.")
		return
	}
	next := *s.Cfg
	next.Name = strings.TrimSpace(req.Name)
	if next.Name == "" {
		writeError(w, "Zadejte název serveru.")
		return
	}
	next.Libraries = nil
	for _, l := range req.Libraries {
		lib := config.Library{Name: strings.TrimSpace(l.Name), Type: l.Type}
		for _, p := range l.Paths {
			p = config.ExpandHome(strings.TrimSpace(p))
			if p == "" {
				continue
			}
			if fi, err := os.Stat(p); err != nil || !fi.IsDir() {
				writeError(w, fmt.Sprintf("Složka %q neexistuje.", p))
				return
			}
			lib.Paths = append(lib.Paths, filepath.Clean(p))
		}
		next.Libraries = append(next.Libraries, lib)
	}
	dts := req.DTS
	next.Transcode.DTS = &dts
	if req.MenuBar != nil {
		mb := *req.MenuBar
		next.MenuBar = &mb
	}
	if req.Remote != nil {
		next.Remote.Enabled = *req.Remote
		if req.Password != "" {
			if len([]rune(req.Password)) < 8 {
				writeError(w, "Heslo musí mít aspoň 8 znaků.")
				return
			}
			hash, err := bcrypt.GenerateFromPassword([]byte(req.Password), bcrypt.DefaultCost)
			if err != nil {
				writeError(w, "Heslo se nepodařilo uložit.")
				return
			}
			next.Remote.PasswordHash = string(hash)
		}
		if next.Remote.Enabled && next.Remote.PasswordHash == "" {
			writeError(w, "Pro přístup z jiných zařízení nastavte heslo.")
			return
		}
	}
	if req.Metadata != nil {
		on := *req.Metadata
		next.Metadata.Enabled = &on
	}
	if req.TMDbToken != nil {
		next.Metadata.TMDbToken = strings.TrimSpace(*req.TMDbToken)
	}
	if req.AutoUpdate != nil {
		auto := *req.AutoUpdate
		next.Updates.Auto = &auto
	}
	if req.HWAccel != "" {
		next.Transcode.HWAccel = req.HWAccel
	}
	if err := next.Validate(); err != nil {
		writeError(w, czechConfigError(err))
		return
	}
	if err := next.Save(s.CfgPath); err != nil {
		slog.Error("save config", "err", err)
		writeError(w, "Nastavení se nepodařilo uložit: "+err.Error())
		return
	}
	if req.Autostart != macos.AutostartEnabled() {
		if err := macos.SetAutostart(req.Autostart); err != nil {
			slog.Error("autostart", "err", err)
		}
	}
	slog.Info("configuration saved, restarting", "libraries", len(next.Libraries))
	writeJSON(w, map[string]bool{"restart": true})
	go func() { time.Sleep(300 * time.Millisecond); s.Restart() }()
}

func czechConfigError(err error) string {
	msg := err.Error()
	switch {
	case strings.Contains(msg, "used twice"):
		return "Dvě knihovny mají stejný název, každá musí mít jiný."
	case strings.Contains(msg, "name is empty"):
		return "Každá knihovna musí mít název."
	case strings.Contains(msg, "no folder"):
		return "Každá knihovna musí mít aspoň jednu složku."
	case strings.Contains(msg, "unknown type"):
		return "Neznámý typ knihovny."
	}
	return msg
}

func (s *Server) pickFolder(w http.ResponseWriter, r *http.Request) {
	if !isLocal(r) {
		writeError(w, "Okno pro výběr složky se otevírá jen na Macu se serverem. Zadejte cestu ručně.")
		return
	}
	path, err := macos.PickFolder(r.Context(), "Vyberte složku s médii pro MinorDLNA")
	switch {
	case errors.Is(err, macos.ErrCancelled):
		writeJSON(w, map[string]string{"path": ""})
	case err != nil:
		slog.Error("folder picker", "err", err)
		writeError(w, "Výběr složky se nepodařilo otevřít, zadejte cestu ručně.")
	default:
		writeJSON(w, map[string]string{"path": path})
	}
}

// lanAddresses lists http://<ip>:port for active IPv4 LAN interfaces.
func lanAddresses(port int) []string {
	var out []string
	ifaces, _ := net.Interfaces()
	for _, ifi := range ifaces {
		if ifi.Flags&net.FlagUp == 0 || ifi.Flags&net.FlagLoopback != 0 || strings.HasPrefix(ifi.Name, "utun") || strings.HasPrefix(ifi.Name, "bridge") {
			continue
		}
		addrs, _ := ifi.Addrs()
		for _, a := range addrs {
			if n, ok := a.(*net.IPNet); ok && n.IP.To4() != nil && !n.IP.IsLinkLocalUnicast() {
				out = append(out, "http://"+n.IP.String()+":"+strconv.Itoa(port))
			}
		}
	}
	return out
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	_ = json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, msg string) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(http.StatusBadRequest)
	_ = json.NewEncoder(w).Encode(map[string]string{"error": msg})
}

// Ping reports whether a MinorDLNA instance already answers on the port.
func Ping(port int) bool {
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	req, _ := http.NewRequestWithContext(ctx, "GET", "http://127.0.0.1:"+strconv.Itoa(port)+"/api/ping", nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	b := make([]byte, 16)
	n, _ := resp.Body.Read(b)
	return string(b[:n]) == "minordlna"
}

func homeDir() string {
	h, _ := os.UserHomeDir()
	return h
}

type browseItem struct {
	ID    string `json:"id"`
	Title string `json:"title"`
	Dir   bool   `json:"dir"`
	Count int    `json:"count"`
	Kind  string `json:"kind,omitempty"`
	Art   string `json:"art,omitempty"`   // card image
	Large string `json:"large,omitempty"` // full-size photo
	Info  string `json:"info,omitempty"`
	// Poster marks a movie or show poster (portrait) rather than a video frame.
	Poster     bool   `json:"poster,omitempty"`
	Desc       string `json:"desc,omitempty"`
	DurationMs int64  `json:"duration_ms,omitempty"`
	PositionMs int64  `json:"position_ms,omitempty"`
	Watched    bool   `json:"watched,omitempty"`
}

// browse lists the same tree the TV sees, with thumbnails for the web library view.
func (s *Server) browse(w http.ResponseWriter, r *http.Request) {
	id := r.URL.Query().Get("id")
	if id == "" {
		id = library.RootID
	}
	start, _ := strconv.Atoi(r.URL.Query().Get("start"))
	count, _ := strconv.Atoi(r.URL.Query().Get("count"))
	if count <= 0 || count > 500 {
		count = 120
	}
	meta, err := s.Cat.Metadata(r.Context(), id)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	objs, total, err := s.Cat.Children(r.Context(), id, max(start, 0), count)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	items := make([]browseItem, 0, len(objs))
	for _, o := range objs {
		it := browseItem{ID: o.ID, Title: o.Title, Dir: o.IsDir, Count: o.ChildCount}
		it.Poster = strings.HasPrefix(o.ArtPath, "/poster/")
		if o.ArtPath != "" {
			// Cards are larger than DLNA thumbnails: use the 640 px rendition.
			it.Art = strings.Replace(o.ArtPath, "/tn.jpg", "/sm.jpg", 1)
		}
		if !o.IsDir {
			it.Desc, it.DurationMs, it.PositionMs, it.Watched = o.Description, o.DurationMs, o.PositionMs, o.Watched
			switch o.Format.Kind {
			case dlna.Image:
				it.Kind = "photo"
				it.Large = strings.Replace(o.ArtPath, "/tn.jpg", "/lrg.jpg", 1)
			case dlna.Audio:
				it.Kind, it.Info = "audio", o.Artist
			default:
				it.Kind = "video"
				if o.DurationMs > 0 {
					it.Info = formatMinutes(o.DurationMs)
				}
				if o.Height > 0 {
					it.Info = strings.TrimPrefix(it.Info+" · "+strconv.Itoa(o.Height)+"p", " · ")
				}
			}
		}
		items = append(items, it)
	}
	writeJSON(w, map[string]any{"id": meta.ID, "title": meta.Title, "parent": meta.ParentID, "total": total, "items": items})
}

func formatMinutes(ms int64) string {
	m := ms / 60000
	if m >= 60 {
		return fmt.Sprintf("%d h %02d min", m/60, m%60)
	}
	return fmt.Sprintf("%d min", max(m, 1))
}
