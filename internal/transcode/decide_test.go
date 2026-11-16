package transcode

import "testing"

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
	for _, p := range []Plan{{"copy", "ac3"}, {"h264", ""}, {"", "flac"}} {
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

func TestDetect(t *testing.T) {
	if Detect("Linux/4.4.84 UPnP/1.0 LGE_DLNA_SDK/1.6.0 [TV][webOS 22]", true).Name != "lg-webos22" {
		t.Error("LG not detected")
	}
	if Detect("VLC/3.0.20 LibVLC/3.0.20", true).Name != "generic" {
		t.Error("generic expected")
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
