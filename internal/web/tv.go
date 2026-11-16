package web

import (
	"encoding/json"
	"net/http"

	"github.com/novami/minor-dlna/internal/renderer"
	"github.com/novami/minor-dlna/internal/transcode"
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
	// Maker and model come from the same place as in Settings, so both lists show a TV alike.
	byIP := map[string]transcode.Client{}
	if s.Profiles != nil {
		for _, c := range s.Profiles.Clients() {
			byIP[c.IP] = c
		}
	}
	type tvRow struct {
		renderer.Device
		Maker string `json:"maker"`
		Model string `json:"model"`
	}
	rows := make([]tvRow, 0, len(devs))
	for _, d := range devs {
		c := byIP[d.IP]
		rows = append(rows, tvRow{Device: d, Maker: c.Maker, Model: c.Model})
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, map[string]any{"devices": rows, "session": s.TV.Status()})
}
