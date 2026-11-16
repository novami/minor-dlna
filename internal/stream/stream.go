// Package stream serves media files with HTTP Range support and DLNA headers.
package stream

import (
	"log/slog"
	"net/http"
	"os"
	"strings"
	"sync/atomic"

	"github.com/novami/minor-dlna/internal/dlna"
	"github.com/novami/minor-dlna/internal/library"
)

const Prefix = "/media/"

var active atomic.Int32

// Active returns the number of media files being sent right now.
func Active() int { return int(active.Load()) }

// Handler serves GET/HEAD requests under Prefix.
func Handler(cat *library.Catalog) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			w.WriteHeader(http.StatusMethodNotAllowed)
			return
		}
		o, err := cat.ResolveMedia(r.Context(), strings.TrimPrefix(r.URL.Path, Prefix))
		if err != nil {
			http.NotFound(w, r)
			return
		}
		f, err := os.Open(o.Path)
		if err != nil {
			http.NotFound(w, r)
			return
		}
		defer f.Close()

		h := w.Header()
		h.Set("Content-Type", o.Format.Mime)
		mode := r.Header.Get("transferMode.dlna.org")
		if mode != "Streaming" && mode != "Interactive" && mode != "Background" {
			mode = dlna.TransferMode(o.Format)
		}
		// Exact header case: some TVs match DLNA headers case-sensitively.
		h["transferMode.dlna.org"] = []string{mode}
		if r.Header.Get("getcontentFeatures.dlna.org") == "1" {
			h["contentFeatures.dlna.org"] = []string{dlna.ContentFeatures(o.Format)}
		}
		if r.Method == http.MethodGet {
			slog.Info("stream", "remote", r.RemoteAddr, "file", o.Title, "range", r.Header.Get("Range"))
		}
		Captions(w, r, o)
		active.Add(1)
		defer active.Add(-1)
		// ServeContent handles Range (206), If-Modified-Since and HEAD.
		http.ServeContent(w, r, "", o.ModTime, f)
	})
}
