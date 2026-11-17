package transcode

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/novami/minor-dlna/internal/library"
)

// DecideBrowser picks direct play for what every current browser plays from an MP4/MP3/FLAC file,
// otherwise a conversion to H.264/HEVC + AAC in fragmented MP4. hevc reports that the browser decodes HEVC.
func DecideBrowser(m Media, hevc bool) Plan {
	if m.Container == "" {
		return Plan{}
	}
	container := normalizeContainer(m.Container)
	if m.Audio {
		if browserAudioFiles[container] && browserAudio[m.AudioCodec] {
			return Plan{}
		}
		return Plan{Audio: "aac"}
	}
	videoOK := (m.VideoCodec == "h264" && !is10Bit(m.PixFmt)) || (m.VideoCodec == "hevc" && hevc)
	audioOK := m.AudioCodec == "" || m.AudioCodec == "aac" || m.AudioCodec == "mp3"
	if container == "mov" && videoOK && audioOK {
		return Plan{}
	}
	p := Plan{Video: "copy", Audio: "copy"}
	if !videoOK {
		p.Video = "h264"
	}
	switch {
	case m.AudioCodec == "":
		p.Audio = ""
	case !audioOK:
		p.Audio = "aac"
	}
	return p
}

var (
	browserAudioFiles = newSet("mp3", "mov", "flac", "wav", "aac")
	browserAudio      = newSet("mp3", "aac", "flac", "pcm_s16le", "pcm_s24le")
)

// browserMux turns base arguments into a browser output; hevc tags copied HEVC as hvc1, which Safari requires.
func browserMux(args []string, p Plan, srcHEVC bool) []string {
	if p.Video == "copy" && srcHEVC {
		args = append(args, "-tag:v", "hvc1")
	}
	return append(args, "-sn", "-dn", "-avoid_negative_ts", "make_zero")
}

// ServeMP4 streams item o as fragmented MP4 from start seconds. Seeking is a new request with another start.
func (s *Service) ServeMP4(w http.ResponseWriter, r *http.Request, o library.Object, p Plan, start float64) {
	args := browserMux(baseArgs(p, o, start, s.hwaccel, false), p, o.VideoCodec == "hevc")
	args = append(args, "-f", "mp4", "-movflags", "frag_keyframe+empty_moov+default_base_moof", "pipe:1")
	if p.Video == "" {
		w.Header().Set("Content-Type", "audio/mp4")
	} else {
		w.Header().Set("Content-Type", "video/mp4")
	}
	w.Header().Set("Cache-Control", "no-store")
	s.pipe(w, r, o, args, "web-"+p.Key(), start)
}

// HLS serves converted streams to Safari, which plays media only with byte ranges or HLS.
// ffmpeg writes segments into a temporary folder that is removed when the player stops asking for it.
type HLS struct {
	svc  *Service
	dir  string
	idle time.Duration

	mu       sync.Mutex
	sessions map[string]*hlsSession
}

type hlsSession struct {
	dir    string
	cancel context.CancelFunc
	last   time.Time
}

func NewHLS(svc *Service, dir string) *HLS {
	os.RemoveAll(dir) // leftovers from a crash
	return &HLS{svc: svc, dir: dir, idle: 2 * time.Minute, sessions: map[string]*hlsSession{}}
}

// Start launches ffmpeg for item o from start seconds and returns the session token.
// hdr comes from ProbeHDR; copied video gets its transfer written into the stream, as a file tagged only
// in its bitstream would otherwise reach the player marked SDR. Dolby Vision profile 5 is copied as dvh1
// with its configuration box, which a player needs to show it at all.
func (h *HLS) Start(ctx context.Context, o library.Object, p Plan, start float64, hdr HDR) (string, error) {
	release, ok := h.svc.acquire(ctx, o.Title)
	if !ok {
		return "", ErrBusy
	}
	b := make([]byte, 16)
	rand.Read(b)
	token := hex.EncodeToString(b)
	dir := filepath.Join(h.dir, token)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		release()
		return "", err
	}
	args := baseArgs(p, o, start, h.svc.hwaccel, true)
	switch {
	case p.Video == "copy" && hdr.DV5():
		args = append(args, "-tag:v", "dvh1", "-strict", "unofficial")
	case p.Video == "copy" && hdr.Transfer != "":
		args = append(args, "-color_primaries", "bt2020", "-color_trc", hdr.Transfer, "-colorspace", "bt2020nc")
	}
	args = browserMux(args, p, o.VideoCodec == "hevc" && !hdr.DV5())
	args = append(args, "-f", "hls", "-hls_time", "4", "-hls_list_size", "0", "-hls_playlist_type", "event",
		"-hls_segment_type", "fmp4", "-hls_flags", "independent_segments+temp_file",
		"-hls_fmp4_init_filename", "init.mp4", "-hls_segment_filename", filepath.Join(dir, "s%05d.m4s"),
		filepath.Join(dir, "index.m3u8"))

	runCtx, cancel := context.WithCancel(context.Background())
	cmd := exec.CommandContext(runCtx, h.svc.ffmpeg, args...)
	var stderr tailBuffer
	cmd.Stderr = &stderr
	if err := cmd.Start(); err != nil {
		cancel()
		release()
		os.RemoveAll(dir)
		return "", err
	}
	h.svc.track(1)
	slog.Info("hls started", "file", o.Title, "plan", p.Key(), "start", start)
	go func() {
		err := cmd.Wait()
		h.svc.track(-1)
		release()
		if err != nil && runCtx.Err() == nil {
			slog.Error("hls failed", "file", o.Title, "err", err, "ffmpeg", stderr.String())
		}
	}()

	h.mu.Lock()
	first := len(h.sessions) == 0
	h.sessions[token] = &hlsSession{dir: dir, cancel: cancel, last: time.Now()}
	h.mu.Unlock()
	if first {
		go h.reap()
	}
	return token, nil
}

// Stop ends a session right away (the player closed or seeked elsewhere).
func (h *HLS) Stop(token string) {
	h.mu.Lock()
	sess := h.sessions[token]
	delete(h.sessions, token)
	h.mu.Unlock()
	if sess != nil {
		sess.close()
	}
}

func (s *hlsSession) close() {
	s.cancel()
	// ffmpeg may still be writing; removal after its exit would race only with an already cancelled process.
	time.AfterFunc(time.Second, func() { os.RemoveAll(s.dir) })
}

func (h *HLS) reap() {
	t := time.NewTicker(15 * time.Second)
	defer t.Stop()
	for range t.C {
		h.mu.Lock()
		for token, sess := range h.sessions {
			if time.Since(sess.last) > h.idle {
				delete(h.sessions, token)
				sess.close()
			}
		}
		empty := len(h.sessions) == 0
		h.mu.Unlock()
		if empty {
			return
		}
	}
}

var hlsFile = regexp.MustCompile(`^(master\.m3u8|index\.m3u8|init\.mp4|s\d{5,6}\.m4s)$`)

// ServeHTTP serves /<token>/<file>. The random token is the access check: Safari's media player may not send cookies.
func (h *HLS) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	token, name, _ := strings.Cut(strings.TrimPrefix(r.URL.Path, "/"), "/")
	h.mu.Lock()
	sess := h.sessions[token]
	if sess != nil {
		sess.last = time.Now()
	}
	h.mu.Unlock()
	if sess == nil || !hlsFile.MatchString(name) {
		http.NotFound(w, r)
		return
	}
	path := filepath.Join(sess.dir, name)
	if !strings.HasSuffix(name, ".m3u8") {
		w.Header().Set("Content-Type", "video/mp4")
		http.ServeFile(w, r, path)
		return
	}
	// The first segments take a moment; Safari gives up on an empty or missing playlist, and AVFoundation
	// drops the variant of a live playlist much shorter than three target durations.
	var b []byte
	path = filepath.Join(sess.dir, "index.m3u8") // the master is built once the media playlist has segments
	for deadline := time.Now().Add(20 * time.Second); time.Now().Before(deadline); {
		var err error
		if b, err = os.ReadFile(path); err == nil && playlistReady(b) {
			break
		}
		select {
		case <-r.Context().Done():
			return
		case <-time.After(200 * time.Millisecond):
		}
	}
	if b == nil {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
	w.Header().Set("Cache-Control", "no-cache")
	if name == "master.m3u8" {
		_, _ = w.Write(masterPlaylist(sess.dir, b))
		return
	}
	_, _ = w.Write(startAtBeginning(b))
}

// playlistReady reports a finished playlist or one listing at least 8 seconds, twice the segment length.
func playlistReady(b []byte) bool {
	if strings.Contains(string(b), "#EXT-X-ENDLIST") {
		return true
	}
	var total float64
	for _, l := range strings.Split(string(b), "\n") {
		if d, ok := strings.CutPrefix(l, "#EXTINF:"); ok {
			v, _ := strconv.ParseFloat(strings.TrimSuffix(strings.TrimSpace(d), ","), 64)
			total += v
		}
	}
	return total >= 8
}

// startAtBeginning: a growing EVENT playlist would otherwise start playing near its live end, skipping the film's start.
func startAtBeginning(b []byte) []byte {
	head, rest, ok := strings.Cut(string(b), "\n")
	if !ok || strings.Contains(rest, "#EXT-X-START") {
		return b
	}
	return []byte(head + "\n#EXT-X-START:TIME-OFFSET=0,PRECISE=YES\n" + rest)
}

// ErrBusy reports that all transcoding slots are in use.
var ErrBusy = errors.New("too many transcoding sessions")

// HDR describes the dynamic range of a video.
type HDR struct {
	Transfer  string // "smpte2084" (PQ), "arib-std-b67" (HLG) or "" for SDR
	DVProfile int    // Dolby Vision profile, 0 without it
}

// DV5 reports Dolby Vision profile 5, whose picture has no usable form without DV processing:
// tone mapping or a player that ignores the DV metadata shows it green and purple.
func (h HDR) DV5() bool { return h.DVProfile == 5 }

// ProbeHDR reads the HDR transfer and the Dolby Vision profile of the video in path. It reads the stream and
// its first frame, as a file may carry the transfer tag only in the container or only in the bitstream.
func (s *Service) ProbeHDR(ctx context.Context, path string) HDR {
	var h HDR
	if s.ffmpeg == "" {
		return h
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	probe := filepath.Join(filepath.Dir(s.ffmpeg), "ffprobe")
	out, _ := exec.CommandContext(ctx, probe, "-v", "error", "-select_streams", "v:0", "-read_intervals", "%+#1",
		"-show_entries", "stream=color_transfer:stream_side_data=dv_profile:frame=color_transfer",
		"-of", "default=nw=1", path).Output()
	for _, line := range strings.Split(string(out), "\n") {
		k, v, _ := strings.Cut(strings.TrimSpace(line), "=")
		switch {
		case k == "color_transfer" && (v == "smpte2084" || v == "arib-std-b67"):
			h.Transfer = v
		case k == "dv_profile":
			h.DVProfile, _ = strconv.Atoi(v)
		}
	}
	if h.DV5() {
		h.Transfer = "smpte2084" // its base layer is IPT-PQ, tagged unspecified or not at all
	}
	return h
}

// Keyframe returns the last video keyframe at or before t seconds. A copied video stream can only start
// at a keyframe, so the player must know where it really begins to keep its clock and subtitles right.
func (s *Service) Keyframe(ctx context.Context, path string, t float64) float64 {
	if t <= 0 || s.ffmpeg == "" {
		return max(t, 0)
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	probe := filepath.Join(filepath.Dir(s.ffmpeg), "ffprobe")
	out, err := exec.CommandContext(ctx, probe, "-v", "error", "-select_streams", "v:0", "-skip_frame", "nokey",
		"-show_entries", "frame=pts_time", "-of", "csv=p=0",
		"-read_intervals", fmt.Sprintf("%.3f%%%.3f", max(t-20, 0), t+0.001), path).Output()
	if err != nil {
		return t
	}
	best := -1.0
	for _, line := range strings.Fields(string(out)) {
		if v, err := strconv.ParseFloat(strings.Trim(line, ","), 64); err == nil && v <= t+0.001 && v > best {
			best = v
		}
	}
	if best < 0 {
		return t
	}
	return best
}
