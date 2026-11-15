package stream

import (
	"bytes"
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
