package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"net/netip"
	"os"
	"os/signal"
	"path/filepath"
	"runtime"
	"strconv"
	"syscall"
	"time"

	"github.com/novami/minor-dlna/internal/config"
	"github.com/novami/minor-dlna/internal/library"
	"github.com/novami/minor-dlna/internal/media"
	"github.com/novami/minor-dlna/internal/ssdp"
	"github.com/novami/minor-dlna/internal/store"
	"github.com/novami/minor-dlna/internal/stream"
	"github.com/novami/minor-dlna/internal/thumbs"
	"github.com/novami/minor-dlna/internal/transcode"
	"github.com/novami/minor-dlna/internal/upnp"
	"github.com/novami/minor-dlna/internal/version"
)

func main() {
	cfgPath := flag.String("config", filepath.Join(config.DefaultDir(), "config.yaml"), "path to config file")
	debug := flag.Bool("debug", false, "verbose logging")
	showVersion := flag.Bool("version", false, "print version and exit")
	flag.Parse()

	if *showVersion {
		fmt.Println(version.Version)
		return
	}
	level := slog.LevelInfo
	if *debug {
		level = slog.LevelDebug
	}
	slog.SetDefault(slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: level})))

	if err := run(*cfgPath); err != nil {
		slog.Error("fatal", "err", err)
		os.Exit(1)
	}
}

func run(cfgPath string) error {
	cfg, err := config.Load(cfgPath)
	if err != nil {
		return err
	}
	if len(cfg.Libraries) == 0 {
		slog.Warn("no libraries configured", "config", cfgPath)
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	st, err := store.Open(filepath.Join(filepath.Dir(cfgPath), "library.db"))
	if err != nil {
		return err
	}
	defer st.Close()
	cat, err := library.NewCatalog(ctx, st, cfg.Libraries)
	if err != nil {
		return err
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
	go scanner.Run(ctx)
	serverName := fmt.Sprintf("%s/1.0 UPnP/1.0 MinorDLNA/%s", runtime.GOOS, version.Version)

	mux := http.NewServeMux()
	dev.Register(mux)
	mux.Handle(stream.Prefix, stream.Handler(cat))
	mux.Handle("/thumb/", th)
	mux.Handle(transcode.Prefix, tc)
	mux.Handle(stream.SubsPrefix, stream.SubsHandler(cat))

	srv := &http.Server{
		Addr:              ":" + strconv.Itoa(cfg.Port),
		Handler:           withCommon(cfg, serverName, mux),
		ReadHeaderTimeout: 10 * time.Second,
		IdleTimeout:       2 * time.Minute,
	}
	ln, err := net.Listen("tcp4", srv.Addr)
	if err != nil {
		return err
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

	slog.Info("MinorDLNA started", "version", version.Version, "name", cfg.Name, "port", cfg.Port, "libraries", len(cfg.Libraries))
	if err := srv.Serve(ln); !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	err = <-ssdpDone
	slog.Info("MinorDLNA stopped")
	return err
}

// withCommon applies the client allowlist and common response headers.
func withCommon(cfg *config.Config, serverName string, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ap, err := netip.ParseAddrPort(r.RemoteAddr)
		if err != nil || !cfg.Allowed(ap.Addr()) {
			slog.Warn("denied", "remote", r.RemoteAddr)
			http.Error(w, "forbidden", http.StatusForbidden)
			return
		}
		w.Header().Set("Server", serverName)
		slog.Debug("http", "method", r.Method, "path", r.URL.Path, "remote", r.RemoteAddr, "ua", r.UserAgent())
		next.ServeHTTP(w, r)
	})
}
