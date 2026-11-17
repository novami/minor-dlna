package transcode

import "testing"

func TestDVCodec(t *testing.T) {
	// profile 5, level 6 (byte 2 = 5<<1, byte 3 = 6<<3 | rpu, bl flags); profile 8, level 13
	for c, want := range map[[4]byte]string{{1, 0, 0x0A, 0x35}: "dvh1.05.06", {1, 0, 0x10, 0x6D}: "dvh1.08.13"} {
		if got := dvCodec("dvh1", c[:]); got != want {
			t.Errorf("dvCodec(% x) = %s, want %s", c, got, want)
		}
	}
}
