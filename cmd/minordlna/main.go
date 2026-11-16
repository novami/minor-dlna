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
	"github.com/novami/minor-dlna/internal/ssdp"
	"github.com/novami/minor-dlna/internal/store"
	"github.com/novami/minor-dlna/internal/stream"
	"github.com/novami/minor-dlna/internal/thumbs"
	"github.com/novami/minor-dlna/internal/transcode"
	"github.com/novami/minor-dlna/internal/upnp"
	"github.com/novami/minor-dlna/internal/version"
	"github.com/novami/minor-dlna/internal/web"
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
	open := *openUI || (inBundle && !*background)

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
	for {
		restart, err := run(ctx, stop, *cfgPath, open)
		if err != nil {
			slog.Error("fatal", "err", err)
			os.Exit(1)
		}
		if !restart {
			return
		}
		open = false
		slog.Info("restarting with new configuration")
	}
}

func uiURL(port int) string { return "http://localhost:" + strconv.Itoa(port) + "/" }

// setupLogging writes to the terminal, or to ~/Library/Logs/MinorDLNA when started from Finder or at login.
func setupLogging(debug bool) {
	level := slog.LevelInfo
	if debug {
		level = slog.LevelDebug
	}
	out := io.Writer(os.Stderr)
	if fi, err := os.Stderr.Stat(); err == nil && fi.Mode()&os.ModeCharDevice == 0 {
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
func run(parent context.Context, quit context.CancelFunc, cfgPath string, openBrowser bool) (bool, error) {
	cfg, err := config.Load(cfgPath)
	if err != nil {
		return false, err
	}
	if len(cfg.Libraries) == 0 {
		slog.Warn("no libraries configured, open the setup page", "url", uiURL(cfg.Port))
	}

	ctx, cancel := context.WithCancel(parent)
	defer cancel()
	var restart atomic.Bool

	st, err := store.Open(filepath.Join(filepath.Dir(cfgPath), "library.db"))
	if err != nil {
		return false, err
	}
	defer st.Close()
	cat, err := library.NewCatalog(ctx, st, cfg.Libraries)
	if err != nil {
		return false, err
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
	scanner.OnChange = func(uint32) { dev.NotifyChange() }
	scanner.OnRemove = th.Purge
	scanDone := make(chan struct{})
	go func() { scanner.Run(ctx); close(scanDone) }()
	serverName := fmt.Sprintf("%s/1.0 UPnP/1.0 MinorDLNA/%s", runtime.GOOS, version.Version)

	mux := http.NewServeMux()
	dev.Register(mux)
	mux.Handle(stream.Prefix, stream.Handler(cat))
	mux.Handle("/thumb/", th)
	mux.Handle(transcode.Prefix, tc)
	mux.Handle(stream.SubsPrefix, stream.SubsHandler(cat))
	ui := &web.Server{
		Cfg: cfg, CfgPath: cfgPath, Cat: cat, Scanner: scanner, Version: version.Version, FFmpeg: ffmpeg != "",
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
		return false, fmt.Errorf("port %d is in use: %w", cfg.Port, err)
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
	if err := srv.Serve(ln); !errors.Is(err, http.ErrServerClosed) {
		return false, err
	}
	err = <-ssdpDone
	<-scanDone // the scanner must finish before the database closes
	if !restart.Load() {
		slog.Info("MinorDLNA stopped")
	}
	return restart.Load(), err
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
