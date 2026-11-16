package web

import (
	"encoding/json"
	"net/http"
)

func (s *Server) registerTV(mux *http.ServeMux) {
	mux.Handle("GET /api/tv", s.local(http.HandlerFunc(s.tvState)))
	mux.Handle("POST /api/tv/search", s.local(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if _, err := s.TV.Search(r.Context()); err != nil {
			writeError(w, "Hledání televizí selhalo: "+err.Error())
			return
		}
		s.tvState(w, r)
	})))
	mux.Handle("POST /api/tv/play", s.local(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			UDN    string `json:"udn"`
			ID     string `json:"id"`
			FromMs int64  `json:"from_ms"`
		}
		if json.NewDecoder(r.Body).Decode(&req) != nil {
			writeError(w, "Neplatný požadavek.")
			return
		}
		if err := s.TV.Play(req.UDN, req.ID, req.FromMs); err != nil {
			writeError(w, err.Error())
			return
		}
		s.tvState(w, r)
	})))
	mux.Handle("POST /api/tv/command", s.local(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Action string `json:"action"`
			Value  int64  `json:"value"`
		}
		if json.NewDecoder(r.Body).Decode(&req) != nil {
			writeError(w, "Neplatný požadavek.")
			return
		}
		if err := s.TV.Command(r.Context(), req.Action, req.Value); err != nil {
			writeError(w, err.Error())
			return
		}
		s.tvState(w, r)
	})))
	mux.Handle("POST /api/tv/wake", s.local(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			UDN string `json:"udn"`
		}
		if json.NewDecoder(r.Body).Decode(&req) != nil {
			writeError(w, "Neplatný požadavek.")
			return
		}
		if err := s.TV.Wake(r.Context(), req.UDN); err != nil {
			writeError(w, err.Error())
			return
		}
		writeJSON(w, map[string]bool{"ok": true})
	})))
}

func (s *Server) tvState(w http.ResponseWriter, r *http.Request) {
	devs, err := s.TV.Devices(r.Context())
	if err != nil {
		writeError(w, err.Error())
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, map[string]any{"devices": devs, "session": s.TV.Status()})
}
