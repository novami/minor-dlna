package web

import (
	"encoding/json"
	"log/slog"
	"net/http"
	"net/netip"
	"sync"

	"github.com/novami/minor-dlna/internal/transcode"
)

var clientsMu sync.Mutex

func (s *Server) registerClients(mux *http.ServeMux) {
	mux.Handle("GET /api/clients", s.local(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		clients := s.Profiles.Clients()
		if clients == nil {
			clients = []transcode.Client{}
		}
		writeJSON(w, map[string]any{"clients": clients, "options": transcode.Options()})
	})))
	// Assigning a profile applies at once (no restart) and is saved for the next start.
	mux.Handle("POST /api/clients/profile", s.local(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			IP      string `json:"ip"`
			Profile string `json:"profile"`
		}
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<12)).Decode(&req); err != nil {
			writeError(w, "Neplatný požadavek.")
			return
		}
		if _, err := netip.ParseAddr(req.IP); err != nil {
			writeError(w, "Neplatná adresa zařízení.")
			return
		}
		clientsMu.Lock()
		defer clientsMu.Unlock()
		if !s.Profiles.Set(req.IP, req.Profile) {
			writeError(w, "Neznámý profil.")
			return
		}
		next := *s.Cfg
		next.Transcode.Clients = s.Profiles.Overrides()
		if err := next.Save(s.CfgPath); err != nil {
			slog.Error("save config", "err", err)
			writeError(w, "Nastavení se nepodařilo uložit: "+err.Error())
			return
		}
		s.Cfg.Transcode.Clients = next.Transcode.Clients
		slog.Info("client profile", "ip", req.IP, "profile", req.Profile)
		writeJSON(w, map[string]bool{"ok": true})
	})))
}
