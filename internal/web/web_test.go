package web

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/novami/minor-dlna/internal/config"
	"github.com/novami/minor-dlna/internal/library"
	"github.com/novami/minor-dlna/internal/media"
	"github.com/novami/minor-dlna/internal/store"
)

func newServer(t *testing.T) (*Server, *httptest.Server, *atomic.Bool) {
	t.Helper()
	t.Setenv("HOME", t.TempDir()) // autostart plist goes to a temp home
	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "config.yaml")
	cfg, err := config.Load(cfgPath)
	if err != nil {
		t.Fatal(err)
	}
	st, err := store.Open(filepath.Join(dir, "db.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	cat, _ := library.NewCatalog(context.Background(), st, nil)
	restarted := &atomic.Bool{}
	s := &Server{Cfg: cfg, CfgPath: cfgPath, Cat: cat, Scanner: library.NewScanner(cat, media.NewProber("/nonexistent")),
		Version: "test", Restart: func() { restarted.Store(true) }, Quit: func() {}}
	mux := http.NewServeMux()
	s.Register(mux)
	ts := httptest.NewServer(mux)
	t.Cleanup(ts.Close)
	return s, ts, restarted
}

func post(t *testing.T, url, body string, header bool) (*http.Response, string) {
	t.Helper()
	req, _ := http.NewRequest("POST", url, strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	if header {
		req.Header.Set("X-MinorDLNA", "1")
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	b := new(strings.Builder)
	buf := make([]byte, 4096)
	n, _ := resp.Body.Read(buf)
	b.Write(buf[:n])
	return resp, b.String()
}

func TestGuard(t *testing.T) {
	_, ts, _ := newServer(t)
	// Foreign Host header (DNS rebinding) is refused even from loopback.
	req, _ := http.NewRequest("GET", ts.URL+"/api/state", nil)
	req.Host = "evil.example:8200"
	resp, _ := http.DefaultClient.Do(req)
	resp.Body.Close()
	if resp.StatusCode != http.StatusForbidden {
		t.Fatalf("rebinding host: %d", resp.StatusCode)
	}
	// Cross-site POST without the custom header is refused.
	if resp, _ := post(t, ts.URL+"/api/quit", "{}", false); resp.StatusCode != http.StatusForbidden {
		t.Fatalf("csrf: %d", resp.StatusCode)
	}
}

func TestSaveConfig(t *testing.T) {
	s, ts, restarted := newServer(t)
	resp, body := post(t, ts.URL+"/api/config", `{"name":"TV","libraries":[{"name":"Filmy","type":"movies","paths":["/neexistuje"]}]}`, true)
	if resp.StatusCode != 400 || !strings.Contains(body, "neexistuje") {
		t.Fatalf("missing folder accepted: %d %s", resp.StatusCode, body)
	}
	media := t.TempDir()
	resp, body = post(t, ts.URL+"/api/config", `{"name":"Obývák","dts":false,"autostart":false,"libraries":[{"name":"Filmy","type":"movies","paths":["`+media+`"]}]}`, true)
	if resp.StatusCode != 200 {
		t.Fatalf("save: %d %s", resp.StatusCode, body)
	}
	saved, err := config.Load(s.CfgPath)
	if err != nil || saved.Name != "Obývák" || len(saved.Libraries) != 1 || saved.Transcode.DTSEnabled() || saved.UUID != s.Cfg.UUID {
		t.Fatalf("saved config %+v %v", saved, err)
	}
	if _, err := os.Stat(s.CfgPath); err != nil {
		t.Fatal(err)
	}
	// Restart is triggered asynchronously.
	for i := 0; i < 50 && !restarted.Load(); i++ {
		time.Sleep(20 * time.Millisecond)
	}
	if !restarted.Load() {
		t.Fatal("restart not triggered")
	}
}
