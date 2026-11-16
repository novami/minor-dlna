package web

import (
	"encoding/json"
	"log/slog"
	"net/http"
	"strconv"
	"strings"
)

func (s *Server) metaList(w http.ResponseWriter, r *http.Request) {
	entries, err := s.Meta.Entries(r.Context())
	if err != nil {
		writeError(w, "Seznam se nepodařilo načíst.")
		return
	}
	writeJSON(w, map[string]any{"enabled": s.Meta.Enabled(), "tmdb": s.Meta.HasTMDb(), "items": entries})
}

func (s *Server) metaSearch(w http.ResponseWriter, r *http.Request) {
	id, _ := strconv.ParseInt(r.URL.Query().Get("id"), 10, 64)
	q := strings.TrimSpace(r.URL.Query().Get("q"))
	if q == "" {
		writeJSON(w, []any{})
		return
	}
	c, err := s.Meta.Search(r.Context(), id, q)
	if err != nil {
		slog.Warn("metadata search", "err", err)
		writeError(w, "Hledání se nepovedlo, zkuste to znovu.")
		return
	}
	writeJSON(w, c)
}

func (s *Server) metaSet(w http.ResponseWriter, r *http.Request) {
	var req struct {
		ID       int64  `json:"id"`
		Wikidata string `json:"wikidata"` // empty = no metadata
		Rematch  bool   `json:"rematch"`  // forget the match and look it up again
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<16)).Decode(&req); err != nil {
		writeError(w, "Neplatný požadavek.")
		return
	}
	var err error
	if req.Rematch {
		err = s.Meta.Rematch(r.Context(), req.ID)
	} else {
		err = s.Meta.Set(r.Context(), req.ID, req.Wikidata)
	}
	if err != nil {
		slog.Warn("metadata match", "err", err)
		writeError(w, "Uložení se nepovedlo, zkuste to znovu.")
		return
	}
	writeJSON(w, map[string]bool{"ok": true})
}
