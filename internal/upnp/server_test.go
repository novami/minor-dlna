package upnp

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
	"github.com/novami/minor-dlna/internal/stream"
)

func setup(t *testing.T) *httptest.Server {
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "Film & co.mp4"), []byte("0123456789"), 0o644)
	ctx := context.Background()
	st, err := store.Open(filepath.Join(t.TempDir(), "db.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	cat, err := library.NewCatalog(ctx, st, []config.Library{{Name: "Filmy", Type: config.Movies, Paths: []string{dir}}})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := library.NewScanner(cat, media.NewProber("/nonexistent")).ScanLibrary(ctx, cat.Libraries()[0]); err != nil {
		t.Fatal(err)
	}
	mux := http.NewServeMux()
	New("Test", "uuid-1", "dev", cat).Register(mux)
	mux.Handle(stream.Prefix, stream.Handler(cat))
	ts := httptest.NewServer(mux)
	t.Cleanup(ts.Close)
	return ts
}

func soap(t *testing.T, url, objectID, flag string) string {
	body := `<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>` +
		`<u:Browse xmlns:u="urn:schemas-upnp-org:service:ContentDirectory:1"><ObjectID>` + objectID + `</ObjectID>` +
		`<BrowseFlag>` + flag + `</BrowseFlag><Filter>*</Filter><StartingIndex>0</StartingIndex><RequestedCount>0</RequestedCount>` +
		`<SortCriteria></SortCriteria></u:Browse></s:Body></s:Envelope>`
	req, _ := http.NewRequest("POST", url+"/cds/control", strings.NewReader(body))
	req.Header.Set("SOAPAction", `"urn:schemas-upnp-org:service:ContentDirectory:1#Browse"`)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return string(b)
}

func TestBrowseAndStream(t *testing.T) {
	ts := setup(t)
	if out := soap(t, ts.URL, "0", "BrowseDirectChildren"); !strings.Contains(out, "&lt;dc:title&gt;Filmy&lt;/dc:title&gt;") {
		t.Fatalf("root missing library: %s", out)
	}
	out := soap(t, ts.URL, "L1/all", "BrowseDirectChildren")
	if !strings.Contains(out, "<TotalMatches>1</TotalMatches>") || !strings.Contains(out, "Film &amp;amp; co") {
		t.Fatalf("unexpected listing: %s", out)
	}
	i := strings.Index(out, ts.URL+"/media/")
	if i < 0 {
		t.Fatalf("no media URL: %s", out)
	}
	mediaURL := out[i : i+strings.Index(out[i:], "&lt;")]

	req, _ := http.NewRequest("GET", mediaURL, nil)
	req.Header.Set("Range", "bytes=2-4")
	req.Header.Set("getcontentFeatures.dlna.org", "1")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusPartialContent || string(b) != "234" {
		t.Fatalf("range: %d %q", resp.StatusCode, b)
	}
	if v := resp.Header["Contentfeatures.dlna.org"]; len(v) == 0 || !strings.Contains(v[0], "DLNA.ORG_OP=01") {
		t.Fatalf("missing contentFeatures: %v", resp.Header)
	}
}

func TestBrowseUnknownObject(t *testing.T) {
	ts := setup(t)
	if out := soap(t, ts.URL, "I999", "BrowseMetadata"); !strings.Contains(out, "<errorCode>701</errorCode>") {
		t.Fatalf("expected 701: %s", out)
	}
}
