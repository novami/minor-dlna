package web

import (
	"io/fs"
	"log/slog"
	"net/http"
	"os"
	"path/filepath"

	"github.com/novami/minor-dlna/internal/macos"
)

type storagePart struct {
	Key       string `json:"key"`
	Title     string `json:"title"`
	Bytes     int64  `json:"bytes"`
	Cleanable bool   `json:"cleanable"` // can be deleted and rebuilt automatically
}

// storageParts lists what the app occupies on disk. Only rebuildable data is cleanable;
// the index and settings are not, removing them would mean a full rescan and a new setup.
func (s *Server) storageParts() []storagePart {
	data := filepath.Dir(s.CfgPath)
	db := filepath.Join(data, "library.db")
	app, _ := macos.AppBundle()
	logs := macos.LogDir()
	parts := []storagePart{
		{Key: "index", Title: "Index knihoven", Bytes: sizeOf(db, db+"-wal", db+"-shm")},
		{Key: "thumbs", Title: "Náhledy (cache)", Bytes: sizeOf(filepath.Join(data, "cache")), Cleanable: true},
		{Key: "backup", Title: "Záloha indexu", Bytes: sizeOf(db + ".bak"), Cleanable: true},
		{Key: "logs", Title: "Protokoly", Bytes: sizeOf(logs), Cleanable: true},
	}
	if app != "" {
		parts = append(parts,
			storagePart{Key: "app", Title: "Aplikace", Bytes: sizeOf(app)},
			storagePart{Key: "previous", Title: "Předchozí verze aplikace", Bytes: sizeOf(app+".prev", app+".failed"), Cleanable: true})
	}
	return parts
}

func (s *Server) storage(w http.ResponseWriter, _ *http.Request) {
	parts := s.storageParts()
	var total, cleanable int64
	for _, p := range parts {
		total += p.Bytes
		if p.Cleanable {
			cleanable += p.Bytes
		}
	}
	writeJSON(w, map[string]any{"parts": parts, "total": total, "cleanable": cleanable})
}

// cleanStorage removes rebuildable data: thumbnails are generated again on demand.
func (s *Server) cleanStorage(w http.ResponseWriter, r *http.Request) {
	data := filepath.Dir(s.CfgPath)
	db := filepath.Join(data, "library.db")
	targets := []string{filepath.Join(data, "cache"), db + ".bak", filepath.Join(macos.LogDir(), "minordlna.log.1")}
	if app, ok := macos.AppBundle(); ok {
		targets = append(targets, app+".prev", app+".failed")
	}
	// The current log keeps running; truncate it instead of deleting the open file.
	if f, err := os.OpenFile(filepath.Join(macos.LogDir(), "minordlna.log"), os.O_WRONLY|os.O_TRUNC, 0); err == nil {
		f.Close()
	}
	for _, t := range targets {
		if err := os.RemoveAll(t); err != nil {
			slog.Warn("clean", "path", t, "err", err)
		}
	}
	slog.Info("storage cleaned")
	s.storage(w, r)
}

func sizeOf(paths ...string) int64 {
	var n int64
	for _, p := range paths {
		_ = filepath.WalkDir(p, func(_ string, d fs.DirEntry, err error) error {
			if err == nil && !d.IsDir() {
				if fi, err := d.Info(); err == nil {
					n += fi.Size()
				}
			}
			return nil
		})
	}
	return n
}
