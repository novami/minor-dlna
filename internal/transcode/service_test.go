package transcode

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/novami/minor-dlna/internal/config"
	"github.com/novami/minor-dlna/internal/library"
	"github.com/novami/minor-dlna/internal/media"
	"github.com/novami/minor-dlna/internal/store"
)

func TestParseNPT(t *testing.T) {
	for in, want := range map[string]float64{"npt=123.5-": 123.5, "npt=0:02:03.5-": 123.5, "npt=10-20": 10, "npt=1:00:00-": 3600} {
		if got, ok := ParseNPT(in); !ok || got != want {
			t.Errorf("%q: %v %v", in, got, ok)
		}
	}
	if _, ok := ParseNPT("bytes=0-"); ok {
		t.Error("bytes accepted")
	}
}

// TestServe runs the handler against a fake ffmpeg that prints its arguments.
func TestServe(t *testing.T) {
	ctx := context.Background()
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "Film (2020).mkv"), []byte("x"), 0o644)
	fake := filepath.Join(t.TempDir(), "ffmpeg")
	os.WriteFile(fake, []byte("#!/bin/sh\necho \"$@\"\n"), 0o755)

	st, err := store.Open(filepath.Join(t.TempDir(), "db.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	cat, _ := library.NewCatalog(ctx, st, []config.Library{{Name: "Filmy", Type: config.Movies, Paths: []string{dir}}})
	if _, err := library.NewScanner(cat, media.NewProber("/nonexistent")).ScanLibrary(ctx, cat.Libraries()[0]); err != nil {
		t.Fatal(err)
	}
	st.DB.Exec(`UPDATE item SET duration_ms = 600000`)

	ts := httptest.NewServer(NewService(fake, "videotoolbox", 1, cat))
	defer ts.Close()
	req, _ := http.NewRequest("GET", ts.URL+"/transcode/1/copy-ac3.ts", nil)
	req.Header.Set("TimeSeekRange.dlna.org", "npt=60-")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	args := string(body)
	if resp.StatusCode != 200 || !strings.Contains(args, "-ss 60.000") || !strings.Contains(args, "-c:v copy") || !strings.Contains(args, "-c:a ac3") {
		t.Fatalf("status %d, args %q", resp.StatusCode, args)
	}
	if got := resp.Header.Get("TimeSeekRange.dlna.org"); got != "npt=60.000-600.000/600.000" {
		t.Fatalf("TimeSeekRange %q", got)
	}
	if strings.Contains(args, "-hwaccel") {
		t.Fatal("hwaccel used without video encoding")
	}

	for _, bad := range []string{"/transcode/1/rm-rf.ts", "/transcode/99/copy-ac3.ts"} {
		r, _ := http.Get(ts.URL + bad)
		r.Body.Close()
		if r.StatusCode != 404 {
			t.Errorf("%s: %d", bad, r.StatusCode)
		}
	}
	if a := strings.Join(Args(Plan{"h264", "aac"}, "in", 0, "videotoolbox"), " "); !strings.Contains(a, "-hwaccel videotoolbox") || !strings.Contains(a, "h264_videotoolbox") {
		t.Fatalf("videotoolbox args: %s", a)
	}
}
