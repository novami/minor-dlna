package renderer

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/novami/minor-dlna/internal/config"
	"github.com/novami/minor-dlna/internal/library"
	"github.com/novami/minor-dlna/internal/media"
	"github.com/novami/minor-dlna/internal/store"
)

const descXML = `<?xml version="1.0"?><root xmlns="urn:schemas-upnp-org:device-1-0"><device>
<deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType><friendlyName>Test TV</friendlyName>
<manufacturer>LG Electronics</manufacturer><modelName>OLED</modelName><UDN>uuid:tv-1</UDN><serviceList>
<service><serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType><controlURL>/avt</controlURL></service>
<service><serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType><controlURL>rc</controlURL></service>
</serviceList></device></root>`

// fakeTV is a renderer that plays whatever it gets until the test changes its state.
type fakeTV struct {
	mu      sync.Mutex
	state   string
	uri     string
	pos     string
	actions []string
}

var reArg = regexp.MustCompile(`<(CurrentURI|Target)>([^<]*)<`)

func (f *fakeTV) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path == "/desc.xml" {
		io.WriteString(w, descXML)
		return
	}
	body, _ := io.ReadAll(r.Body)
	action := strings.Trim(r.Header.Get("SOAPAction"), `"`)
	action = action[strings.Index(action, "#")+1:]
	args := map[string]string{}
	for _, m := range reArg.FindAllStringSubmatch(string(body), -1) {
		args[m[1]] = m[2]
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	out := ""
	switch action {
	case "SetAVTransportURI":
		f.uri, f.state, f.pos = args["CurrentURI"], "STOPPED", "0:00:00"
	case "Play":
		f.state = "PLAYING"
	case "Stop":
		f.state = "STOPPED"
	case "Seek":
		f.pos = args["Target"]
		action += " " + args["Target"]
	case "GetTransportInfo":
		out = "<CurrentTransportState>" + f.state + "</CurrentTransportState>"
	case "GetPositionInfo":
		out = "<RelTime>" + f.pos + "</RelTime><TrackDuration>0:10:00</TrackDuration><TrackURI>" + f.uri + "</TrackURI>"
	case "GetVolume":
		out = "<CurrentVolume>12</CurrentVolume>"
	case "GetMute":
		out = "<CurrentMute>0</CurrentMute>"
	}
	if !strings.HasPrefix(action, "Get") {
		f.actions = append(f.actions, action)
	}
	io.WriteString(w, `<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><u:R>`+out+`</u:R></s:Body></s:Envelope>`)
}

func (f *fakeTV) set(state, pos string) {
	f.mu.Lock()
	f.state, f.pos = state, pos
	f.mu.Unlock()
}

func (f *fakeTV) has(action string) bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	for _, a := range f.actions {
		if a == action {
			return true
		}
	}
	return false
}

func waitFor(t *testing.T, what string, ok func() bool) {
	t.Helper()
	for deadline := time.Now().Add(5 * time.Second); time.Now().Before(deadline); time.Sleep(10 * time.Millisecond) {
		if ok() {
			return
		}
	}
	t.Fatalf("timed out waiting for %s", what)
}

func TestDescribe(t *testing.T) {
	srv := httptest.NewServer(&fakeTV{})
	defer srv.Close()
	d, err := Describe(context.Background(), srv.URL+"/desc.xml")
	if err != nil {
		t.Fatal(err)
	}
	if d.UDN != "uuid:tv-1" || d.Name != "Test TV" || d.avt != srv.URL+"/avt" || d.rc != srv.URL+"/rc" {
		t.Fatalf("%+v", d)
	}
}

func TestPlayResumeAndNextEpisode(t *testing.T) {
	pollEvery = 20 * time.Millisecond
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	dir := t.TempDir()
	for _, f := range []string{"Show/S01E01.mkv", "Show/S01E02.mkv"} {
		os.MkdirAll(filepath.Join(dir, filepath.Dir(f)), 0o755)
		os.WriteFile(filepath.Join(dir, f), []byte("x"), 0o644)
	}
	st, err := store.Open(filepath.Join(t.TempDir(), "db.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	cat, err := library.NewCatalog(ctx, st, []config.Library{{Name: "Seriály", Type: config.Shows, Paths: []string{dir}}})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := library.NewScanner(cat, media.NewProber("/nonexistent")).ScanLibrary(ctx, cat.Libraries()[0]); err != nil {
		t.Fatal(err)
	}
	var ep1 string
	_ = st.DB.QueryRow(`SELECT 'I' || id FROM item WHERE episode = 1`).Scan(&ep1)

	tv := &fakeTV{}
	srv := httptest.NewServer(tv)
	defer srv.Close()
	st.DB.Exec(`INSERT INTO renderer (udn, name, location, ip, seen_at) VALUES ('uuid:tv-1', 'Test TV', ?, '127.0.0.1', 0)`, srv.URL+"/desc.xml")

	c := &Controller{DB: st.DB, Cat: cat, Port: 8200}
	go c.Run(ctx)
	waitFor(t, "controller", func() bool { c.mu.Lock(); defer c.mu.Unlock(); return c.ctx != nil })

	if err := c.Play("uuid:tv-1", ep1, 100_000); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "resume seek 5 s early", func() bool { return tv.has("Seek 0:01:35") })

	// Played to the end: marked watched, the next episode follows.
	tv.set("PLAYING", "0:09:55")
	waitFor(t, "position", func() bool { s := c.Status(); return s != nil && s.PositionMs == 595_000 })
	tv.set("STOPPED", "0:00:00")
	waitFor(t, "next episode", func() bool { s := c.Status(); return s != nil && s.ItemID != ep1 && s.State == "PLAYING" })
	if o, _ := cat.Metadata(ctx, ep1); !o.Watched {
		t.Fatal("episode 1 not marked watched")
	}

	// Stopped half way: the position is kept for resuming.
	tv.set("PLAYING", "0:04:00")
	waitFor(t, "position", func() bool { s := c.Status(); return s != nil && s.PositionMs == 240_000 })
	next := c.Status().ItemID
	if err := c.Command(ctx, "stop", 0); err != nil {
		t.Fatal(err)
	}
	if s := c.Status(); s == nil || s.State != "STOPPED" {
		t.Fatalf("status after stop: %+v", s)
	}
	if o, _ := cat.Metadata(ctx, next); o.PositionMs != 240_000 || o.Watched {
		t.Fatalf("episode 2: position %d watched %v", o.PositionMs, o.Watched)
	}
}

func TestParseTime(t *testing.T) {
	for in, want := range map[string]int64{"1:02:03": 3_723_000, "0:00:01.500": 1_500, "NOT_IMPLEMENTED": 0} {
		if got, _ := parseTime(in); got != want {
			t.Errorf("%s: %d", in, got)
		}
	}
}
