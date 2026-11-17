package transcode

import (
	"strings"
	"testing"

	"github.com/novami/minor-dlna/internal/library"
)

func TestDecide(t *testing.T) {
	lg := LGWebOS22(false)
	cases := []struct {
		name string
		m    Media
		want Plan
	}{
		{"mkv hevc eac3 direct", Media{Container: "matroska,webm", VideoCodec: "hevc", AudioCodec: "eac3", Channels: 6}, Plan{}},
		{"mkv truehd → ac3", Media{Container: "matroska,webm", VideoCodec: "hevc", AudioCodec: "truehd", Channels: 8}, Plan{"copy", "ac3"}},
		{"dts stereo → aac", Media{Container: "matroska,webm", VideoCodec: "h264", AudioCodec: "dts", Channels: 2}, Plan{"copy", "aac"}},
		{"wmv → h264", Media{Container: "asf", VideoCodec: "wmv3", AudioCodec: "wmav2", Channels: 2}, Plan{"h264", "aac"}},
		{"10-bit h264", Media{Container: "matroska,webm", VideoCodec: "h264", PixFmt: "yuv420p10le", AudioCodec: "aac"}, Plan{"h264", "copy"}},
		{"flv remux", Media{Container: "flv", VideoCodec: "h264", AudioCodec: "aac"}, Plan{"copy", "copy"}},
		{"unprobed", Media{}, Plan{}},
		{"alac → flac", Media{Audio: true, Container: "mov,mp4,m4a", AudioCodec: "alac"}, Plan{Audio: "flac"}},
		{"flac direct", Media{Audio: true, Container: "flac", AudioCodec: "flac"}, Plan{}},
	}
	for _, c := range cases {
		if got := Decide(lg, c.m); got != c.want {
			t.Errorf("%s: got %+v, want %+v", c.name, got, c.want)
		}
	}
	if !Decide(Generic, Media{Container: "asf", VideoCodec: "wmv3"}).Direct() {
		t.Error("generic profile should play directly")
	}
	if Decide(LGWebOS22(true), Media{Container: "matroska", VideoCodec: "h264", AudioCodec: "dts"}) != (Plan{}) {
		t.Error("dts enabled should play directly")
	}
}

func TestKey(t *testing.T) {
	for _, p := range []Plan{{"copy", "ac3"}, {"h264", ""}, {"sdr", "copy"}, {"", "flac"}} {
		got, ok := ParseKey(p.Key())
		if !ok || got != p {
			t.Errorf("%+v → %q → %+v %v", p, p.Key(), got, ok)
		}
	}
	for _, bad := range []string{"x-x", "rm-rf", "copy", "copy-ac3;ls"} {
		if _, ok := ParseKey(bad); ok {
			t.Errorf("%q accepted", bad)
		}
	}
}

func TestSDRArgs(t *testing.T) {
	args := func(codec, hwaccel string) string {
		return strings.Join(baseArgs(Plan{Video: "sdr"}, library.Object{Path: "f.mkv", VideoCodec: codec}, 0, hwaccel, false), " ")
	}
	if a := args("hevc", "videotoolbox"); !strings.Contains(a, "videotoolbox_vld") || strings.Contains(a, "hwupload") {
		t.Errorf("HEVC not tone-mapped on VideoToolbox frames: %s", a)
	}
	// VideoToolbox does not decode AV1 before M3, and fails instead of falling back.
	if a := args("av1", "videotoolbox"); strings.Contains(a, "-hwaccel ") || !strings.Contains(a, "hwupload,scale_vt") {
		t.Errorf("AV1 not decoded in software: %s", a)
	}
	if a := args("hevc", "none"); !strings.Contains(a, "libx264") || !strings.Contains(a, "hwdownload") {
		t.Errorf("tone mapping without hardware encoding: %s", a)
	}
}

func TestDecideBrowser(t *testing.T) {
	for _, c := range []struct {
		m    Media
		hevc bool
		want Plan
	}{
		{Media{Container: "mov,mp4,m4a", VideoCodec: "h264", AudioCodec: "aac"}, false, Plan{}},
		{Media{Container: "matroska,webm", VideoCodec: "h264", AudioCodec: "ac3"}, false, Plan{"copy", "aac"}},
		{Media{Container: "mov,mp4", VideoCodec: "hevc", AudioCodec: "aac"}, false, Plan{"h264", "copy"}},
		{Media{Container: "mov,mp4", VideoCodec: "hevc", AudioCodec: "aac"}, true, Plan{}},
		{Media{Container: "matroska", VideoCodec: "h264", PixFmt: "yuv420p10le"}, false, Plan{Video: "h264"}},
		{Media{Audio: true, Container: "flac", AudioCodec: "flac"}, false, Plan{}},
		{Media{Audio: true, Container: "mov,mp4,m4a", AudioCodec: "alac"}, false, Plan{Audio: "aac"}},
	} {
		if got := DecideBrowser(c.m, c.hevc); got != c.want {
			t.Errorf("%+v hevc=%v: %+v, want %+v", c.m, c.hevc, got, c.want)
		}
	}
}

func TestDetectBrands(t *testing.T) {
	cases := map[string]string{
		"Linux/3.10 UPnP/1.0 LGE_DLNA_SDK/1.6.0 DLNADOC/1.50":              "lg",
		"SEC_HHP_[TV] Samsung Q80 Series (55)/1.0 DLNADOC/1.50":            "samsung",
		"X-AV-Client-Info: av=5.0; cn=\"Sony Corporation\"; mn=\"BRAVIA\"": "sony",
		"Panasonic MIL DLNA CP UPnP/1.0 DLNADOC/1.50":                      "panasonic",
		"Hisense HU55A6 VIDAA":                                             "hisense",
		"Roku 55R635 TCL":                                                  "roku",
		"TCL Smart TV Google TV":                                           "android",
		"Dalvik/2.1.0 (Linux; U; Android 11; BRAVIA 4K VH2)":               "sony",
		"Toshiba TV UPnP/1.0 DLNADOC/1.50":                                 "tv",
		"VLC/3.0.20 LibVLC/3.0.20":                                         "generic",
	}
	for ident, want := range cases {
		if got := DetectID(ident); got != want {
			t.Errorf("%q: got %s, want %s", ident, got, want)
		}
	}
}

func TestResolver(t *testing.T) {
	r := NewResolver(false, map[string]string{"10.0.0.9": "panasonic", "10.0.0.8": "bogus"})
	// The browser User-Agent names no brand, the renderer description does.
	r.ObserveDevice("10.0.0.5", "Obývák", "Samsung Electronics.", "QE55Q80")
	if c := r.Clients()[0]; c.Maker != "Samsung Electronics" || c.Model != "QE55Q80" {
		t.Errorf("device: got %q %q", c.Maker, c.Model)
	}
	if p := r.For("10.0.0.5", "Linux UPnP/1.0"); p.Name != "samsung" {
		t.Errorf("merged ident: got %s", p.Name)
	}
	if p := r.For("10.0.0.9", "LGE webOS"); p.Name != "panasonic" {
		t.Errorf("override: got %s", p.Name)
	}
	if _, ok := r.Overrides()["10.0.0.8"]; ok {
		t.Error("unknown profile kept")
	}
	if r.Set("10.0.0.5", "nope") || !r.Set("10.0.0.5", "generic") || r.For("10.0.0.5", "").Name != "generic" {
		t.Error("set override")
	}
	samsung, _ := ByName("samsung", false)
	if Decide(samsung, Media{Container: "matroska", VideoCodec: "hevc", AudioCodec: "dts", Channels: 6}) != (Plan{"copy", "ac3"}) {
		t.Error("samsung without dts should convert audio")
	}
	android, _ := ByName("android", true)
	if Decide(android, Media{Container: "avi", VideoCodec: "mpeg4", AudioCodec: "mp3", Channels: 2}) != (Plan{"h264", "copy"}) {
		t.Error("android avi/mpeg4 should convert")
	}
}

func TestOptionsCoverBrands(t *testing.T) {
	if len(Options()) != len(brands)+1 {
		t.Error("a brand is missing from the settings options")
	}
}
