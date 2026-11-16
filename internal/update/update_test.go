package update

import (
	"archive/zip"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestCompare(t *testing.T) {
	cases := []struct {
		a, b string
		want int
	}{
		{"v1.2.3", "v1.2.3", 0}, {"v1.10.0", "v1.9.9", 1}, {"v1.0.0-rc.1", "v1.0.0", -1}, {"v2.0.0", "v1.99.99", 1},
	}
	for _, c := range cases {
		if got := Compare(c.a, c.b); got != c.want {
			t.Errorf("%s vs %s: %d", c.a, c.b, got)
		}
	}
	if IsVersion("dev") || IsVersion("b3b5f11-dirty") || !IsVersion("v0.1.0") {
		t.Error("IsVersion")
	}
}

// fakeRelease builds a zipped app whose binary prints its version, plus signed checksums.
func fakeRelease(t *testing.T, version string, priv ed25519.PrivateKey, tamper bool) *httptest.Server {
	t.Helper()
	zipPath := filepath.Join(t.TempDir(), "app.zip")
	f, _ := os.Create(zipPath)
	zw := zip.NewWriter(f)
	h := &zip.FileHeader{Name: "MinorDLNA.app/Contents/MacOS/minordlna", Method: zip.Deflate}
	h.SetMode(0o755)
	w, _ := zw.CreateHeader(h)
	fmt.Fprintf(w, "#!/bin/sh\necho %s\n", version)
	w, _ = zw.Create("MinorDLNA.app/Contents/Info.plist")
	w.Write([]byte("<plist/>"))
	zw.Close()
	f.Close()
	data, _ := os.ReadFile(zipPath)
	if tamper {
		data = append(data, 0)
	}
	name := "MinorDLNA-" + version + "-macos.zip"
	sum := sha256.Sum256(data)
	sums := hex.EncodeToString(sum[:]) + "  " + name + "\n"
	if tamper {
		sum := sha256.Sum256(data[:len(data)-1])
		sums = hex.EncodeToString(sum[:]) + "  " + name + "\n"
	}
	sig := base64.StdEncoding.EncodeToString(ed25519.Sign(priv, []byte(sums)))

	mux := http.NewServeMux()
	var srv *httptest.Server
	mux.HandleFunc("/repos/novami/minor-dlna/releases", func(w http.ResponseWriter, _ *http.Request) {
		json.NewEncoder(w).Encode([]map[string]any{{
			"tag_name": version, "body": "Novinky", "html_url": "x",
			"assets": []map[string]string{
				{"name": name, "browser_download_url": srv.URL + "/zip"},
				{"name": "checksums.txt", "browser_download_url": srv.URL + "/sums"},
				{"name": "checksums.txt.sig", "browser_download_url": srv.URL + "/sig"},
			},
		}})
	})
	mux.HandleFunc("/zip", func(w http.ResponseWriter, _ *http.Request) { w.Write(data) })
	mux.HandleFunc("/sums", func(w http.ResponseWriter, _ *http.Request) { w.Write([]byte(sums)) })
	mux.HandleFunc("/sig", func(w http.ResponseWriter, _ *http.Request) { w.Write([]byte(sig)) })
	srv = httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return srv
}

func installedApp(t *testing.T) string {
	app := filepath.Join(t.TempDir(), "MinorDLNA.app")
	os.MkdirAll(filepath.Join(app, "Contents", "MacOS"), 0o755)
	os.WriteFile(filepath.Join(app, "Contents", "MacOS", "minordlna"), []byte("old"), 0o755)
	return app
}

func TestInstall(t *testing.T) {
	pub, priv, _ := ed25519.GenerateKey(rand.Reader)
	key := base64.StdEncoding.EncodeToString(pub)
	ctx := context.Background()

	srv := fakeRelease(t, "v1.1.0", priv, false)
	c := &Client{HTTP: srv.Client(), API: srv.URL, PublicKey: key}
	if _, err := c.Latest(ctx, "v1.1.0", false); err != ErrNoUpdate {
		t.Fatalf("same version offered: %v", err)
	}
	rel, err := c.Latest(ctx, "v1.0.0", false)
	if err != nil || rel.Version != "v1.1.0" {
		t.Fatalf("latest: %+v %v", rel, err)
	}
	app := installedApp(t)
	exe, err := c.Install(ctx, rel, app)
	if err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(exe); !strings.Contains(string(b), "v1.1.0") {
		t.Fatal("new binary not in place")
	}
	if b, _ := os.ReadFile(filepath.Join(app+".prev", "Contents", "MacOS", "minordlna")); string(b) != "old" {
		t.Fatal("previous app not kept")
	}
	if _, err := Rollback(app); err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(filepath.Join(app, "Contents", "MacOS", "minordlna")); string(b) != "old" {
		t.Fatal("rollback failed")
	}

	// Signed with another key → rejected, app untouched.
	_, other, _ := ed25519.GenerateKey(rand.Reader)
	srv2 := fakeRelease(t, "v1.2.0", other, false)
	c2 := &Client{HTTP: srv2.Client(), API: srv2.URL, PublicKey: key}
	rel2, _ := c2.Latest(ctx, "v1.0.0", false)
	app2 := installedApp(t)
	if _, err := c2.Install(ctx, rel2, app2); err == nil || !strings.Contains(err.Error(), "signature") {
		t.Fatalf("foreign signature accepted: %v", err)
	}
	// Valid signature but altered zip → checksum mismatch.
	srv3 := fakeRelease(t, "v1.3.0", priv, true)
	c3 := &Client{HTTP: srv3.Client(), API: srv3.URL, PublicKey: key}
	rel3, _ := c3.Latest(ctx, "v1.0.0", false)
	if _, err := c3.Install(ctx, rel3, app2); err == nil || !strings.Contains(err.Error(), "checksum") {
		t.Fatalf("tampered zip accepted: %v", err)
	}
	if b, _ := os.ReadFile(filepath.Join(app2, "Contents", "MacOS", "minordlna")); string(b) != "old" {
		t.Fatal("app changed after failed install")
	}
}

// TestRealRelease installs a release built by the pipeline steps; set MINORDLNA_RELEASE_DIR
// to a folder with the zip, checksums.txt and checksums.txt.sig signed with the real key.
func TestRealRelease(t *testing.T) {
	dir := os.Getenv("MINORDLNA_RELEASE_DIR")
	if dir == "" {
		t.Skip("set MINORDLNA_RELEASE_DIR")
	}
	zips, _ := filepath.Glob(filepath.Join(dir, "MinorDLNA-*-macos.zip"))
	if len(zips) != 1 {
		t.Fatal("expected one zip")
	}
	name := filepath.Base(zips[0])
	version := strings.TrimSuffix(strings.TrimPrefix(name, "MinorDLNA-"), "-macos.zip")
	srv := httptest.NewServer(http.FileServer(http.Dir(dir)))
	defer srv.Close()
	rel := &Release{Version: version, zipName: name, zipURL: srv.URL + "/" + name,
		sumsURL: srv.URL + "/checksums.txt", sigURL: srv.URL + "/checksums.txt.sig"}
	app := installedApp(t)
	exe, err := NewClient().Install(context.Background(), rel, app)
	if err != nil {
		t.Fatal(err)
	}
	if out, err := exec.Command("codesign", "--verify", "--deep", "--strict", app).CombinedOutput(); err != nil {
		t.Fatalf("signature broken after install: %s", out)
	}
	t.Log("installed", exe)
}
