package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/netip"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"runtime"
	"strconv"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/novami/minor-dlna/internal/config"
	"github.com/novami/minor-dlna/internal/library"
	"github.com/novami/minor-dlna/internal/macos"
	"github.com/novami/minor-dlna/internal/media"
	"github.com/novami/minor-dlna/internal/metadata"
	"github.com/novami/minor-dlna/internal/renderer"
	"github.com/novami/minor-dlna/internal/ssdp"
	"github.com/novami/minor-dlna/internal/store"
	"github.com/novami/minor-dlna/internal/stream"
	"github.com/novami/minor-dlna/internal/thumbs"
	"github.com/novami/minor-dlna/internal/transcode"
	"github.com/novami/minor-dlna/internal/tray"
	"github.com/novami/minor-dlna/internal/update"
	"github.com/novami/minor-dlna/internal/upnp"
	"github.com/novami/minor-dlna/internal/version"
	"github.com/novami/minor-dlna/internal/web"
	"golang.org/x/sys/unix"
)

func main() {
	cfgPath := flag.String("config", filepath.Join(config.DefaultDir(), "config.yaml"), "path to config file")
	debug := flag.Bool("debug", false, "verbose logging")
	showVersion := flag.Bool("version", false, "print version and exit")
	background := flag.Bool("background", false, "do not open the browser (login item)")
	openUI := flag.Bool("open", false, "open the management page in the browser")
	flag.Parse()

	if *showVersion {
		fmt.Println(version.Version)
		return
	}
	setupLogging(*debug)

	_, inBundle := macos.AppBundle()
	open := *openUI || (inBundle && !*background && os.Getenv("MINORDLNA_NO_OPEN") == "")
	os.Unsetenv("MINORDLNA_NO_OPEN")

	cfg, err := config.Load(*cfgPath)
	if err != nil {
		slog.Error("fatal", "err", err)
		os.Exit(1)
	}
	// Second launch (e.g. double-click while running): just show the running instance.
	if web.Ping(cfg.Port) {
		if open {
			_ = macos.OpenURL(uiURL(cfg.Port))
		}
		return
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	marker := filepath.Join(filepath.Dir(*cfgPath), "update-pending")
	useTray := inBundle && cfg.MenuBarEnabled()
	var live atomic.Pointer[current]

	serve := func() int {
		for {
			res, err := run(ctx, stop, *cfgPath, open, marker, &live)
			if err != nil {
				slog.Error("fatal", "err", err)
				// A freshly installed version that cannot start is replaced by the previous one.
				if app, ok := macos.AppBundle(); ok && fileExists(marker) {
					os.Remove(marker)
					if exe, rerr := update.Rollback(app); rerr == nil {
						slog.Warn("update failed to start, rolled back to the previous version")
						execInto(exe)
					}
				}
				return 1
			}
			switch {
			case res.exe != "":
				// New version installed: continue as the new binary in the same process.
				_ = os.WriteFile(marker, []byte(version.Version), 0o644)
				execInto(res.exe)
				return 1
			case !res.restart:
				return 0
			}
			open = false
			// The menu bar icon lives for the whole process: toggling it needs a fresh process.
			if next, err := config.Load(*cfgPath); err == nil && inBundle && next.MenuBarEnabled() != useTray {
				if exe, err := os.Executable(); err == nil {
					os.Setenv("MINORDLNA_NO_OPEN", "1")
					execInto(exe)
				}
			}
			slog.Info("restarting with new configuration")
		}
	}

	if !useTray {
		os.Exit(serve())
	}
	// Cocoa needs the main thread for the menu bar, so the server runs alongside.
	var code atomic.Int32
	go func() {
		code.Store(int32(serve()))
		tray.Stop()
	}()
	tray.Run(trayActions(&live, stop))
	os.Exit(int(code.Load()))
}

// current exposes the running server's parts to the menu bar; replaced on every in-process restart.
type current struct {
	cfg     *config.Config
	scanner *library.Scanner
	upd     *update.Manager
	tc      *transcode.Service
}

func trayActions(live *atomic.Pointer[current], quit context.CancelFunc) tray.Actions {
	get := func() *current { return live.Load() }
	return tray.Actions{
		Status: func() tray.Status {
			c := get()
			if c == nil {
				return tray.Status{}
			}
			st := tray.Status{Name: c.cfg.Name, Running: true, Streams: stream.Active() + c.tc.Active(), Scanning: c.scanner.Scanning()}
			if l := c.upd.State().Latest; l != nil {
				st.UpdateVer = l.Version
			}
			return st
		},
		OpenUI: func(tab string) {
			if c := get(); c != nil {
				url := uiURL(c.cfg.Port)
				if tab != "" {
					url += "#" + tab
				}
				_ = macos.OpenURL(url)
			}
		},
		Rescan: func() {
			if c := get(); c != nil {
				c.scanner.Rescan()
			}
		},
		CheckUpdate: func() (string, error) {
			c := get()
			if c == nil {
				return "", nil
			}
			ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
			defer cancel()
			rel, err := c.upd.Check(ctx)
			if err != nil || rel == nil {
				return "", err
			}
			return rel.Version, nil
		},
		InstallUpdate: func() {
			if c := get(); c != nil {
				go func() { _ = c.upd.Install(context.Background()) }()
			}
		},
		ShowLog: func() {
			_ = exec.Command("/usr/bin/open", "-a", "Console", filepath.Join(macos.LogDir(), "minordlna.log")).Run()
		},
		Quit: quit,
	}
}

// execInto replaces the process with another executable, keeping the arguments.
func execInto(exe string) {
	args := append([]string{exe}, os.Args[1:]...)
	if err := syscall.Exec(exe, args, os.Environ()); err != nil {
		slog.Error("exec new version", "err", err)
	}
}

func fileExists(p string) bool {
	_, err := os.Stat(p)
	return err == nil
}

type runResult struct {
	restart bool   // configuration changed
	exe     string // update installed: exec this binary
}

func uiURL(port int) string { return "http://localhost:" + strconv.Itoa(port) + "/" }

// setupLogging writes to the terminal, or to ~/Library/Logs/MinorDLNA when started from Finder or at login.
func setupLogging(debug bool) {
	level := slog.LevelInfo
	if debug {
		level = slog.LevelDebug
	}
	out := io.Writer(os.Stderr)
	// Finder and launchd connect stderr to /dev/null, which is a character device but not a terminal.
	if _, err := unix.IoctlGetTermios(int(os.Stderr.Fd()), unix.TIOCGETA); err != nil {
		dir := macos.LogDir()
		path := filepath.Join(dir, "minordlna.log")
		if err := os.MkdirAll(dir, 0o755); err == nil {
			if fi, err := os.Stat(path); err == nil && fi.Size() > 10<<20 {
				_ = os.Rename(path, path+".1")
			}
			if f, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644); err == nil {
				out = f
			}
		}
	}
	slog.SetDefault(slog.New(slog.NewTextHandler(out, &slog.HandlerOptions{Level: level})))
}

// run serves until quit (returns false) or until a saved configuration asks for a restart (returns true).
func run(parent context.Context, quit context.CancelFunc, cfgPath string, openBrowser bool, marker string, live *atomic.Pointer[current]) (runResult, error) {
	cfg, err := config.Load(cfgPath)
	if err != nil {
		return runResult{}, err
	}
	if len(cfg.Libraries) == 0 {
		slog.Warn("no libraries configured, open the setup page", "url", uiURL(cfg.Port))
	}

	ctx, cancel := context.WithCancel(parent)
	defer cancel()
	var restart atomic.Bool
	var newExe atomic.Value

	st, err := store.Open(filepath.Join(filepath.Dir(cfgPath), "library.db"))
	if err != nil {
		return runResult{}, err
	}
	defer st.Close()
	cat, err := library.NewCatalog(ctx, st, cfg.Libraries)
	if err != nil {
		return runResult{}, err
	}
	ffmpeg := cfg.Transcode.FFmpeg
	if ffmpeg == "" {
		ffmpeg = thumbs.FindFFmpeg()
	}
	if ffmpeg == "" {
		slog.Warn("ffmpeg not found: no transcoding or video thumbnails, unsupported formats will not play; install with: brew install ffmpeg")
	}
	cat.VideoThumbs = ffmpeg != ""
	th := thumbs.New(filepath.Join(filepath.Dir(cfgPath), "cache", "thumbs"), ffmpeg, cat)
	dev := upnp.New(cfg.Name, cfg.UUID, version.Version, cat)
	dev.DTS, dev.CanTranscode = cfg.Transcode.DTSEnabled(), ffmpeg != ""
	tc := transcode.NewService(ffmpeg, cfg.Transcode.HWAccel, cfg.Transcode.MaxSessions, cat)
	tc.Captions = stream.Captions
	probe := ""
	if cfg.Transcode.FFmpeg != "" {
		probe = filepath.Join(filepath.Dir(cfg.Transcode.FFmpeg), "ffprobe")
	}
	scanner := library.NewScanner(cat, media.NewProber(probe))
	// Posters live outside cache/: the index refers to them and storage cleanup empties cache/.
	meta := metadata.New(st, filepath.Join(filepath.Dir(cfgPath), "posters"), cfg.Metadata)
	meta.OnChange = func() {
		if _, err := st.BumpUpdateID(ctx); err == nil {
			dev.NotifyChange()
		}
	}
	go meta.Run(ctx)
	scanner.OnChange = func(uint32) { dev.NotifyChange(); meta.Kick() }
	scanner.OnRemove = th.Purge
	scanDone := make(chan struct{})
	go func() { scanner.Run(ctx); close(scanDone) }()
	serverName := fmt.Sprintf("%s/1.0 UPnP/1.0 MinorDLNA/%s", runtime.GOOS, version.Version)

	mux := http.NewServeMux()
	dev.Register(mux)
	mux.Handle(stream.Prefix, stream.Handler(cat))
	mux.Handle("/thumb/", th)
	mux.Handle("/poster/", meta)
	mux.Handle(transcode.Prefix, tc)
	mux.Handle(stream.SubsPrefix, stream.SubsHandler(cat))
	appPath, _ := macos.AppBundle()
	upd := &update.Manager{
		Client: update.NewClient(), Current: version.Version, AppPath: appPath,
		Auto:       cfg.Updates.AutoEnabled,
		Prerelease: cfg.Updates.Channel == "prerelease",
		Busy:       func() bool { return stream.Active() > 0 || tc.Active() > 0 },
		Installed:  func(exe string) { newExe.Store(exe); cancel() },
	}
	go upd.Run(ctx)
	live.Store(&current{cfg: cfg, scanner: scanner, upd: upd, tc: tc})
	defer live.Store(nil)
	tv := &renderer.Controller{
		DB: st.DB, Cat: cat, Port: cfg.Port, Interfaces: cfg.Interfaces,
		DTS: cfg.Transcode.DTSEnabled(), Transcode: ffmpeg != "",
		OnProgress: func() {
			if _, err := st.BumpUpdateID(ctx); err == nil {
				dev.NotifyChange()
			}
		},
	}
	tvDone := make(chan struct{})
	go func() { tv.Run(ctx); close(tvDone) }()
	ui := &web.Server{
		Cfg: cfg, CfgPath: cfgPath, Cat: cat, Scanner: scanner, Version: version.Version, FFmpeg: ffmpeg != "", Updates: upd, Meta: meta, TV: tv,
		Restart: func() { restart.Store(true); cancel() },
		Quit:    quit,
	}
	ui.Register(mux)

	srv := &http.Server{
		Addr:              ":" + strconv.Itoa(cfg.Port),
		Handler:           withCommon(cfg, serverName, mux),
		ReadHeaderTimeout: 10 * time.Second,
		IdleTimeout:       2 * time.Minute,
	}
	ln, err := net.Listen("tcp4", srv.Addr)
	if err != nil {
		return runResult{}, fmt.Errorf("port %d is in use: %w", cfg.Port, err)
	}

	disc := &ssdp.Server{
		UUID:       cfg.UUID,
		Port:       cfg.Port,
		Path:       upnp.DescPath,
		ServerName: serverName,
		DeviceType: upnp.DeviceType,
		Services:   []string{upnp.CDSType, upnp.CMSType},
		Interfaces: cfg.Interfaces,
	}
	ssdpDone := make(chan error, 1)
	go func() {
		err := disc.Run(ctx)
		if err != nil {
			slog.Error("discovery disabled, TV will not find the server", "err", err)
		}
		ssdpDone <- err
	}()

	go func() {
		<-ctx.Done()
		sctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = srv.Shutdown(sctx)
	}()

	slog.Info("MinorDLNA started", "version", version.Version, "name", cfg.Name, "port", cfg.Port, "libraries", len(cfg.Libraries), "ui", uiURL(cfg.Port))
	if openBrowser {
		go func() { _ = macos.OpenURL(uiURL(cfg.Port)) }()
	}
	if fileExists(marker) && appPath != "" {
		// First start after an update: once it has run for a minute, drop the previous version.
		go func() {
			select {
			case <-time.After(time.Minute):
				os.Remove(marker)
				update.Cleanup(appPath)
				slog.Info("update confirmed", "version", version.Version)
			case <-ctx.Done():
			}
		}()
	}
	if err := srv.Serve(ln); !errors.Is(err, http.ErrServerClosed) {
		return runResult{}, err
	}
	err = <-ssdpDone
	<-scanDone // the scanner must finish before the database closes
	<-tvDone
	exe, _ := newExe.Load().(string)
	if !restart.Load() && exe == "" {
		slog.Info("MinorDLNA stopped")
	}
	return runResult{restart: restart.Load(), exe: exe}, err
}

// withCommon applies the client allowlist and common response headers.
func withCommon(cfg *config.Config, serverName string, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ap, err := netip.ParseAddrPort(r.RemoteAddr)
		// This Mac is always allowed, so the management page can't be locked out by the allow list.
		if err != nil || (!ap.Addr().IsLoopback() && !cfg.Allowed(ap.Addr())) {
			slog.Warn("denied", "remote", r.RemoteAddr)
			http.Error(w, "forbidden", http.StatusForbidden)
			return
		}
		w.Header().Set("Server", serverName)
		slog.Debug("http", "method", r.Method, "path", r.URL.Path, "remote", r.RemoteAddr, "ua", r.UserAgent())
		next.ServeHTTP(w, r)
	})
}
