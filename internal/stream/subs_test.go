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
