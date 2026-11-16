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
	"github.com/novami/minor-dlna/internal/library"
	"github.com/novami/minor-dlna/internal/macos"
)

//go:embed static
var staticFS embed.FS

type Server struct {
	Cfg     *config.Config
	CfgPath string
	Cat     *library.Catalog
	Scanner *library.Scanner
	Version string
	FFmpeg  bool
	Restart func() // apply a saved config
	Quit    func()
}

func (s *Server) Register(mux *http.ServeMux) {
	static, _ := fs.Sub(staticFS, "static")
	mux.Handle("GET /{$}", s.local(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		http.ServeFileFS(w, r, static, "index.html")
	})))
	mux.Handle("GET /static/", s.local(http.StripPrefix("/static/", http.FileServerFS(static))))
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
	mux.Handle("POST /api/quit", s.local(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, map[string]bool{"ok": true})
		go func() { time.Sleep(300 * time.Millisecond); s.Quit() }()
	})))
}

// local restricts management to this Mac and blocks cross-site requests:
// the client must be loopback, the Host must be a loopback name (defeats DNS rebinding),
// and state-changing requests need a custom header that browsers only send from our own page.
func (s *Server) local(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		host, _, _ := net.SplitHostPort(r.RemoteAddr)
		ip := net.ParseIP(host)
		reqHost := r.Host
		if h, _, err := net.SplitHostPort(r.Host); err == nil {
			reqHost = h
		}
		if ip == nil || !ip.IsLoopback() || (reqHost != "localhost" && reqHost != "127.0.0.1" && reqHost != "::1") {
			http.Error(w, "Správa je dostupná jen na tomto Macu: http://localhost:"+portOf(r), http.StatusForbidden)
			return
		}
		if r.Method != http.MethodGet && r.Header.Get("X-MinorDLNA") != "1" {
			http.Error(w, "forbidden", http.StatusForbidden)
			return
		}
		next.ServeHTTP(w, r)
	})
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
	Version      string        `json:"version"`
	Name         string        `json:"name"`
	ComputerName string        `json:"computer_name"`
	SetupNeeded  bool          `json:"setup_needed"`
	Autostart    bool          `json:"autostart"`
	FFmpeg       bool          `json:"ffmpeg"`
	Scanning     bool          `json:"scanning"`
	Addresses    []string      `json:"addresses"`
	Libraries    []libraryJSON `json:"libraries"`
	DTS          bool          `json:"dts"`
	HWAccel      string        `json:"hwaccel"`
	Suggestions  []libraryJSON `json:"suggestions"`
	Home         string        `json:"home"`
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
		FFmpeg: s.FFmpeg, Scanning: s.Scanner.Scanning(), Addresses: lanAddresses(s.Cfg.Port),
		Libraries: libs, DTS: s.Cfg.Transcode.DTSEnabled(), HWAccel: s.Cfg.Transcode.HWAccel,
		Suggestions: suggestions(), Home: homeDir(),
	})
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
	DTS       bool   `json:"dts"`
	HWAccel   string `json:"hwaccel"`
	Autostart bool   `json:"autostart"`
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
