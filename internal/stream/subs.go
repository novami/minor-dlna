package stream

import (
	"bytes"
	"fmt"
	"io"
	"net/http"
	"os"
	"strconv"
	"strings"
	"unicode/utf8"

	"golang.org/x/text/encoding/charmap"

	"github.com/novami/minor-dlna/internal/library"
)

const SubsPrefix = "/subs/"

// SubtitlePath is the URL path of an item's external subtitles.
func SubtitlePath(itemID string) string {
	return SubsPrefix + strings.TrimPrefix(itemID, "I") + ".srt"
}

// Captions announces external subtitles to the TV (CaptionInfo.sec header used by TV media players).
func Captions(w http.ResponseWriter, r *http.Request, o library.Object) {
	if o.Subtitle != "" {
		w.Header()["CaptionInfo.sec"] = []string{"http://" + r.Host + SubtitlePath(o.ID)}
	}
}

// SubsHandler serves .srt files as UTF-8; legacy Czech subtitles are usually Windows-1250.
func SubsHandler(cat *library.Catalog) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		idStr := strings.TrimSuffix(strings.TrimPrefix(r.URL.Path, SubsPrefix), ".srt")
		if _, err := strconv.ParseInt(idStr, 10, 64); err != nil {
			http.NotFound(w, r)
			return
		}
		o, err := cat.Metadata(r.Context(), "I"+idStr)
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
		data = ToUTF8(data)
		w.Header().Set("Content-Type", "text/srt; charset=utf-8")
		w.Header().Set("Content-Length", strconv.Itoa(len(data)))
		if r.Method != http.MethodHead {
			w.Write(data)
		}
	})
}

// ToUTF8 strips a BOM and converts non-UTF-8 text from Windows-1250.
func ToUTF8(data []byte) []byte {
	data = bytes.TrimPrefix(data, []byte("\xef\xbb\xbf"))
	if utf8.Valid(data) {
		return data
	}
	if out, err := charmap.Windows1250.NewDecoder().Bytes(data); err == nil {
		return out
	}
	return data
}

// SRTToVTT converts SubRip to WebVTT for browsers, moving cues shift seconds earlier
// (a converted stream that starts mid-file has its timeline start at zero). Cues that end before zero are dropped.
func SRTToVTT(srt []byte, shift float64) []byte {
	var b bytes.Buffer
	b.WriteString("WEBVTT\n\n")
	lines := strings.Split(strings.ReplaceAll(string(ToUTF8(srt)), "\r\n", "\n"), "\n")
	for i := 0; i < len(lines); i++ {
		from, to, ok := strings.Cut(lines[i], "-->")
		if !ok {
			continue
		}
		start, ok1 := srtTime(from)
		end, ok2 := srtTime(to)
		var text []string
		for i++; i < len(lines) && strings.TrimSpace(lines[i]) != ""; i++ {
			text = append(text, lines[i])
		}
		if !ok1 || !ok2 || end-shift <= 0 || len(text) == 0 {
			continue
		}
		b.WriteString(vttTime(max(start-shift, 0)) + " --> " + vttTime(end-shift) + "\n")
		b.WriteString(strings.Join(text, "\n") + "\n\n")
	}
	return b.Bytes()
}

// srtTime reads "01:02:03,456" (optionally followed by cue settings) as seconds.
func srtTime(s string) (float64, bool) {
	f := strings.Fields(s)
	if len(f) == 0 {
		return 0, false
	}
	parts := strings.Split(strings.Replace(f[0], ",", ".", 1), ":")
	if len(parts) != 3 {
		return 0, false
	}
	var secs float64
	for _, p := range parts {
		v, err := strconv.ParseFloat(p, 64)
		if err != nil || v < 0 {
			return 0, false
		}
		secs = secs*60 + v
	}
	return secs, true
}

func vttTime(secs float64) string {
	ms := int64(secs*1000 + 0.5)
	return fmt.Sprintf("%02d:%02d:%02d.%03d", ms/3600000, ms/60000%60, ms/1000%60, ms%1000)
}
