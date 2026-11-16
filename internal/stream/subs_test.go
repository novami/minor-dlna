package stream

import "testing"

func TestToUTF8(t *testing.T) {
	cp1250 := []byte{'P', 0xF8, 0xED, 'l', 'i', 0x9A}
	if got := string(ToUTF8(cp1250)); got != "Příliš" {
		t.Fatalf("got %q", got)
	}
	if got := string(ToUTF8([]byte("\xef\xbb\xbfŽluť"))); got != "Žluť" {
		t.Fatalf("got %q", got)
	}
}

func TestSRTToVTT(t *testing.T) {
	srt := "1\r\n00:00:05,000 --> 00:00:08,500\r\nPryč\r\n\r\n2\r\n00:01:00,000 --> 00:01:02,250\r\nDva\r\nřádky\r\n"
	want := "WEBVTT\n\n00:00:50.000 --> 00:00:52.250\nDva\nřádky\n\n"
	if got := string(SRTToVTT([]byte(srt), 10)); got != want {
		t.Fatalf("got %q", got)
	}
}
