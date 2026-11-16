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

func remoteGet(t *testing.T, url string, cookie *http.Cookie) int {
	t.Helper()
	req, _ := http.NewRequest("GET", url, nil)
	req.Host = "192.168.1.7:8200" // looks like another device
	if cookie != nil {
		req.AddCookie(cookie)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	return resp.StatusCode
}

func remotePost(t *testing.T, url, body string) *http.Response {
	t.Helper()
	req, _ := http.NewRequest("POST", url, strings.NewReader(body))
	req.Host = "192.168.1.7:8200"
	req.Header.Set("X-MinorDLNA", "1")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	return resp
}

func TestRemoteLogin(t *testing.T) {
	s, ts, _ := newServer(t)
	if code := remoteGet(t, ts.URL+"/api/state", nil); code != http.StatusForbidden {
		t.Fatalf("remote disabled: %d", code)
	}
	resp, body := post(t, ts.URL+"/api/config", `{"name":"TV","remote":true,"password":"kratke"}`, true)
	if resp.StatusCode != 400 || !strings.Contains(body, "8 znaků") {
		t.Fatalf("short password accepted: %s", body)
	}
	if resp, body := post(t, ts.URL+"/api/config", `{"name":"TV","remote":true,"password":"tajneheslo"}`, true); resp.StatusCode != 200 {
		t.Fatalf("enable remote: %s", body)
	}
	saved, _ := config.Load(s.CfgPath)
	s.Cfg = saved // the real server restarts with the saved config
	if code := remoteGet(t, ts.URL+"/api/state", nil); code != http.StatusUnauthorized {
		t.Fatalf("without session: %d", code)
	}
	if code := remoteGet(t, ts.URL+"/", nil); code != 200 {
		t.Fatalf("login page not reachable: %d", code)
	}
	if r := remotePost(t, ts.URL+"/api/login", `{"password":"spatne"}`); r.StatusCode != 400 {
		t.Fatalf("wrong password: %d", r.StatusCode)
	}
	r := remotePost(t, ts.URL+"/api/login", `{"password":"tajneheslo"}`)
	var cookie *http.Cookie
	for _, c := range r.Cookies() {
		if c.Name == sessionCookie {
			cookie = c
		}
	}
	if r.StatusCode != 200 || cookie == nil || !cookie.HttpOnly || cookie.SameSite != http.SameSiteStrictMode {
		t.Fatalf("login: %d %+v", r.StatusCode, cookie)
	}
	if code := remoteGet(t, ts.URL+"/api/state", cookie); code != 200 {
		t.Fatalf("with session: %d", code)
	}
	// Brute force: locked after repeated failures, even with the right password.
	for range maxFailures {
		remotePost(t, ts.URL+"/api/login", `{"password":"spatne"}`)
	}
	if r := remotePost(t, ts.URL+"/api/login", `{"password":"tajneheslo"}`); r.StatusCode != 400 {
		t.Fatalf("not locked out: %d", r.StatusCode)
	}
}
