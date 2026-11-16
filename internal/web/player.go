package web

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strconv"
	"strings"

	"github.com/novami/minor-dlna/internal/dlna"
	"github.com/novami/minor-dlna/internal/library"
	"github.com/novami/minor-dlna/internal/stream"
	"github.com/novami/minor-dlna/internal/transcode"
)

// The web player: direct files where the browser plays them, otherwise fragmented MP4 (or HLS for Safari)
// started at a given time. Seeking in a converted stream restarts it from the new time.
func (s *Server) registerPlayer(mux *http.ServeMux) {
	mux.Handle("GET /api/play", s.local(http.HandlerFunc(s.playInfo)))
	mux.Handle("GET /api/play/{id}/stream.mp4", s.local(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		o, plan, ok := s.playable(w, r, r.PathValue("id"), r.URL.Query().Get("hevc") == "1")
		if !ok {
			return
		}
		if plan.Direct() {
			http.Redirect(w, r, o.MediaPath, http.StatusFound)
			return
		}
		s.Transcode.ServeMP4(w, r, o, plan, seconds(r.URL.Query().Get("t")))
	})))
	// start positions a converted stream: at the keyframe before t when the video is copied, as HLS for Safari.
	mux.Handle("POST /api/play/start", s.local(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			ID   string  `json:"id"`
			T    float64 `json:"t"`
			HEVC bool    `json:"hevc"`
			HLS  bool    `json:"hls"`
			Stop string  `json:"stop"` // the previous HLS session of this player
		}
		if json.NewDecoder(r.Body).Decode(&req) != nil {
			writeError(w, "Neplatný požadavek.")
			return
		}
		if req.Stop != "" {
			s.HLS.Stop(req.Stop)
		}
		num := strings.TrimPrefix(req.ID, "I")
		o, plan, ok := s.playable(w, r, num, req.HEVC)
		if !ok {
			return
		}
		if plan.Direct() {
			writeError(w, "Soubor se přehrává přímo.")
			return
		}
		start := max(req.T, 0)
		if plan.Video == "copy" {
			start = s.Transcode.Keyframe(r.Context(), o.Path, start)
		}
		if !req.HLS {
			url := fmt.Sprintf("/api/play/%s/stream.mp4?t=%.3f", num, start)
			if req.HEVC {
				url += "&hevc=1"
			}
			writeJSON(w, map[string]any{"url": url, "start": start})
			return
		}
		token, err := s.HLS.Start(r.Context(), o, plan, start)
		if err != nil {
			if err == transcode.ErrBusy {
				writeError(w, "Server právě převádí jiná videa, zkuste to za chvíli.")
			} else {
				writeError(w, "Převod se nepodařilo spustit: "+err.Error())
			}
			return
		}
		writeJSON(w, map[string]any{"url": "/hls/" + token + "/index.m3u8", "token": token, "start": start})
	})))
	mux.Handle("POST /api/play/hls/stop", s.local(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Token string `json:"token"`
		}
		if json.NewDecoder(r.Body).Decode(&req) == nil {
			s.HLS.Stop(req.Token)
		}
		writeJSON(w, map[string]bool{"ok": true})
	})))
	mux.Handle("GET /hls/", http.StripPrefix("/hls", s.HLS))
	mux.Handle("GET /api/play/{id}/subs.vtt", s.local(http.HandlerFunc(s.subsVTT)))
	mux.Handle("POST /api/position", s.local(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			ID         string `json:"id"`
			PositionMs int64  `json:"position_ms"`
			DurationMs int64  `json:"duration_ms"`
		}
		if json.NewDecoder(r.Body).Decode(&req) != nil || req.PositionMs <= 0 {
			writeError(w, "Neplatný požadavek.")
			return
		}
		if err := s.Cat.SavePosition(r.Context(), req.ID, req.PositionMs, req.DurationMs); err != nil {
			writeError(w, "Pozici se nepodařilo uložit.")
			return
		}
		writeJSON(w, map[string]bool{"ok": true})
	})))
}

type playJSON struct {
	ID         string    `json:"id"`
	Title      string    `json:"title"`
	Kind       string    `json:"kind"`
	Art        string    `json:"art,omitempty"`
	DurationMs int64     `json:"duration_ms"`
	PositionMs int64     `json:"position_ms"`
	Watched    bool      `json:"watched"`
	Direct     bool      `json:"direct"`
	Src        string    `json:"src"` // direct: the file; otherwise the MP4 stream without ?t=
	Subs       bool      `json:"subs"`
	Next       *nextJSON `json:"next,omitempty"`
}

type nextJSON struct {
	ID    string `json:"id"`
	Title string `json:"title"`
}

func (s *Server) playInfo(w http.ResponseWriter, r *http.Request) {
	o, plan, ok := s.playable(w, r, strings.TrimPrefix(r.URL.Query().Get("id"), "I"), r.URL.Query().Get("hevc") == "1")
	if !ok {
		return
	}
	p := playJSON{
		ID: o.ID, Title: o.Title, Kind: "video", DurationMs: o.DurationMs, PositionMs: o.PositionMs, Watched: o.Watched,
		Direct: plan.Direct(), Src: o.MediaPath, Subs: o.Subtitle != "",
		Art: strings.Replace(o.ArtPath, "/tn.jpg", "/sm.jpg", 1),
	}
	if o.Format.Kind == dlna.Audio {
		p.Kind = "audio"
	}
	if !p.Direct {
		p.Src = "/api/play/" + strings.TrimPrefix(o.ID, "I") + "/stream.mp4"
	}
	if n, ok := s.Cat.NextEpisode(r.Context(), o.ID); ok {
		p.Next = &nextJSON{ID: n.ID, Title: n.Title}
	}
	writeJSON(w, p)
}

// playable loads a video or audio item by its number and decides how the browser gets it.
func (s *Server) playable(w http.ResponseWriter, r *http.Request, num string, hevc bool) (library.Object, transcode.Plan, bool) {
	if _, err := strconv.ParseInt(num, 10, 64); err != nil {
		http.NotFound(w, r)
		return library.Object{}, transcode.Plan{}, false
	}
	o, err := s.Cat.Metadata(r.Context(), "I"+num)
	if err != nil || o.IsDir || (o.Format.Kind != dlna.Video && o.Format.Kind != dlna.Audio) {
		http.NotFound(w, r)
		return library.Object{}, transcode.Plan{}, false
	}
	var plan transcode.Plan
	if s.Transcode != nil && s.Transcode.Available() {
		plan = transcode.DecideBrowser(transcode.Media{
			Audio: o.Format.Kind == dlna.Audio, Container: o.Container, VideoCodec: o.VideoCodec,
			AudioCodec: o.AudioCodec, PixFmt: o.PixFmt, Channels: o.Channels,
		}, hevc)
	}
	return o, plan, true
}

func (s *Server) subsVTT(w http.ResponseWriter, r *http.Request) {
	num := r.PathValue("id")
	if _, err := strconv.ParseInt(num, 10, 64); err != nil {
		http.NotFound(w, r)
		return
	}
	o, err := s.Cat.Metadata(r.Context(), "I"+num)
	if err != nil || o.Subtitle == "" {
		http.NotFound(w, r)
		return
	}
	f, err := os.Open(o.Subtitle)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	defer f.Close()
	data, err := io.ReadAll(io.LimitReader(f, 5<<20))
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/vtt; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.Write(stream.SRTToVTT(data, seconds(r.URL.Query().Get("t"))))
}

func seconds(v string) float64 {
	f, err := strconv.ParseFloat(v, 64)
	if err != nil || !(f >= 0 && f <= 1e6) { // also rejects NaN
		return 0
	}
	return f
}
