package transcode

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/novami/minor-dlna/internal/dlna"
	"github.com/novami/minor-dlna/internal/library"
)

const Prefix = "/transcode/"

// Mime returns the content type of a plan's output.
func Mime(p Plan) string {
	if p.Video == "" {
		return "audio/flac"
	}
	return "video/mpeg"
}

// Ext returns the URL extension of a plan's output.
func Ext(p Plan) string {
	if p.Video == "" {
		return ".flac"
	}
	return ".ts"
}

// ContentFeatures announces time-based seeking only: the output size is unknown, so byte ranges are not offered.
func ContentFeatures() string {
	return "DLNA.ORG_OP=10;DLNA.ORG_CI=1;DLNA.ORG_FLAGS=01700000000000000000000000000000"
}

func ProtocolInfo(p Plan) string { return "http-get:*:" + Mime(p) + ":" + ContentFeatures() }

// Path is the URL path of a converted stream.
func Path(itemID string, p Plan) string {
	return Prefix + strings.TrimPrefix(itemID, "I") + "/" + p.Key() + Ext(p)
}

type Service struct {
	ffmpeg  string
	hwaccel string // "videotoolbox" or "none"
	cat     *library.Catalog
	slots   chan struct{}
	// Captions adds subtitle headers to the response, shared with direct streaming.
	Captions func(w http.ResponseWriter, r *http.Request, o library.Object)

	mu     sync.Mutex
	active int
}

func NewService(ffmpeg, hwaccel string, maxSessions int, cat *library.Catalog) *Service {
	return &Service{ffmpeg: ffmpeg, hwaccel: hwaccel, cat: cat, slots: make(chan struct{}, max(maxSessions, 1))}
}

func (s *Service) Available() bool { return s.ffmpeg != "" }

func (s *Service) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	idStr, file, _ := strings.Cut(strings.TrimPrefix(r.URL.Path, Prefix), "/")
	key := file
	if i := strings.LastIndexByte(file, '.'); i >= 0 {
		key = file[:i]
	}
	plan, ok := ParseKey(key)
	if _, err := strconv.ParseInt(idStr, 10, 64); err != nil || !ok || s.ffmpeg == "" {
		http.NotFound(w, r)
		return
	}
	o, err := s.cat.Metadata(r.Context(), "I"+idStr)
	if err != nil || (o.Format.Kind != dlna.Video && o.Format.Kind != dlna.Audio) {
		http.NotFound(w, r)
		return
	}

	var start float64
	dur := float64(o.DurationMs) / 1000
	h := w.Header()
	if tsr := r.Header.Get("TimeSeekRange.dlna.org"); tsr != "" {
		from, ok := ParseNPT(tsr)
		if !ok || (dur > 0 && from >= dur) {
			w.WriteHeader(http.StatusRequestedRangeNotSatisfiable)
			return
		}
		start = from
		if dur > 0 {
			h["TimeSeekRange.dlna.org"] = []string{fmt.Sprintf("npt=%.3f-%.3f/%.3f", start, dur, dur)}
		}
	}
	h.Set("Content-Type", Mime(plan))
	h["transferMode.dlna.org"] = []string{"Streaming"}
	if r.Header.Get("getcontentFeatures.dlna.org") == "1" {
		h["contentFeatures.dlna.org"] = []string{ContentFeatures()}
	}
	if s.Captions != nil {
		s.Captions(w, r, o)
	}
	if r.Method == http.MethodHead {
		w.WriteHeader(http.StatusOK)
		return
	}

	// A player often reconnects immediately; give the previous ffmpeg a moment to exit.
	wait, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()
	select {
	case s.slots <- struct{}{}:
		defer func() { <-s.slots }()
	case <-wait.Done():
		slog.Warn("transcode refused, all sessions busy", "file", o.Title)
		http.Error(w, "too many transcoding sessions", http.StatusServiceUnavailable)
		return
	}

	args := Args(plan, o.Path, start, s.hwaccel)
	cmd := exec.CommandContext(r.Context(), s.ffmpeg, args...)
	var stderr tailBuffer
	cmd.Stderr = &stderr
	out, err := cmd.StdoutPipe()
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	if err := cmd.Start(); err != nil {
		slog.Error("ffmpeg start", "err", err)
		http.Error(w, "transcoder failed", http.StatusInternalServerError)
		return
	}
	s.mu.Lock()
	s.active++
	s.mu.Unlock()
	slog.Info("transcode started", "file", o.Title, "plan", plan.Key(), "start", start, "remote", r.RemoteAddr)
	began := time.Now()

	w.WriteHeader(http.StatusOK)
	n, copyErr := io.Copy(flushWriter{w}, out)
	waitErr := cmd.Wait()

	s.mu.Lock()
	s.active--
	s.mu.Unlock()
	switch {
	case r.Context().Err() != nil:
		slog.Info("transcode stopped by client", "file", o.Title, "sent_mb", n>>20, "took", time.Since(began).Round(time.Second))
	case waitErr != nil:
		slog.Error("transcode failed", "file", o.Title, "err", waitErr, "ffmpeg", stderr.String())
	case copyErr != nil:
		slog.Info("transcode connection closed", "file", o.Title, "err", copyErr)
	default:
		slog.Info("transcode finished", "file", o.Title, "sent_mb", n>>20)
	}
}

// Active returns the number of running ffmpeg processes.
func (s *Service) Active() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.active
}

// Args builds the ffmpeg command line for a plan.
func Args(p Plan, path string, start float64, hwaccel string) []string {
	args := []string{"-nostdin", "-hide_banner", "-v", "error", "-fflags", "+genpts"}
	if start > 0 {
		args = append(args, "-ss", strconv.FormatFloat(start, 'f', 3, 64))
	}
	if p.Video == "h264" && hwaccel == "videotoolbox" {
		args = append(args, "-hwaccel", "videotoolbox")
	}
	args = append(args, "-i", path)

	if p.Video == "" {
		// Audio-only output.
		return append(args, "-map", "0:a:0", "-vn", "-c:a", "flac", "-f", "flac", "pipe:1")
	}

	args = append(args, "-map", "0:v:0")
	if p.Audio != "" {
		args = append(args, "-map", "0:a:0?")
	}
	switch p.Video {
	case "copy":
		args = append(args, "-c:v", "copy")
	case "h264":
		// Cap at 1080p: sources needing H.264 are older formats, and it keeps encoding real-time.
		args = append(args, "-vf", "scale=w='min(1920,iw)':h=-2,format=yuv420p")
		if hwaccel == "videotoolbox" {
			args = append(args, "-c:v", "h264_videotoolbox", "-profile:v", "high", "-b:v", "10M", "-maxrate", "15M", "-bufsize", "20M")
		} else {
			args = append(args, "-c:v", "libx264", "-preset", "veryfast", "-crf", "20", "-profile:v", "high")
		}
	}
	switch p.Audio {
	case "copy":
		args = append(args, "-c:a", "copy")
	case "ac3":
		args = append(args, "-c:a", "ac3", "-b:a", "640k", "-ac", "6")
	case "aac":
		args = append(args, "-c:a", "aac", "-b:a", "192k", "-ac", "2")
	}
	return append(args, "-sn", "-dn", "-f", "mpegts", "-muxdelay", "0", "-muxpreload", "0", "pipe:1")
}

// ParseNPT reads the start of "npt=123.4-", "npt=0:02:03.5-" or "npt=10-20" in seconds.
func ParseNPT(h string) (float64, bool) {
	v, ok := strings.CutPrefix(strings.TrimSpace(h), "npt=")
	if !ok {
		return 0, false
	}
	from, _, _ := strings.Cut(v, "-")
	if from == "" || from == "now" {
		return 0, from == "now" || from == ""
	}
	parts := strings.Split(from, ":")
	if len(parts) > 3 {
		return 0, false
	}
	var secs float64
	for _, p := range parts {
		f, err := strconv.ParseFloat(p, 64)
		if err != nil || f < 0 {
			return 0, false
		}
		secs = secs*60 + f
	}
	return secs, true
}

type flushWriter struct{ w http.ResponseWriter }

func (f flushWriter) Write(p []byte) (int, error) {
	n, err := f.w.Write(p)
	if fl, ok := f.w.(http.Flusher); ok {
		fl.Flush()
	}
	return n, err
}

// tailBuffer keeps the last few KB of ffmpeg's error output for logging.
type tailBuffer struct{ buf bytes.Buffer }

func (t *tailBuffer) Write(p []byte) (int, error) {
	t.buf.Write(p)
	if t.buf.Len() > 4096 {
		b := t.buf.Bytes()[t.buf.Len()-4096:]
		t.buf.Reset()
		t.buf.Write(b)
	}
	return len(p), nil
}

func (t *tailBuffer) String() string { return strings.TrimSpace(t.buf.String()) }
