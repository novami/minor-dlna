package transcode

import (
	"encoding/binary"
	"fmt"
	"math/bits"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// iOS aborts every segment download of a bare media playlist; it needs a master playlist that states
// bandwidth and codecs. ffmpeg leaves CODECS out for HEVC, so the master is built here from init.mp4.

// masterPlaylist describes the stream in dir, whose media playlist already lists a segment.
func masterPlaylist(dir string, media []byte) []byte {
	info := initInfo(filepath.Join(dir, "init.mp4"))
	attrs := []string{"BANDWIDTH=" + strconv.Itoa(firstSegmentBandwidth(dir, media))}
	if len(info.codecs) > 0 {
		attrs = append(attrs, `CODECS="`+strings.Join(info.codecs, ",")+`"`)
	}
	if info.width > 0 && info.height > 0 {
		attrs = append(attrs, fmt.Sprintf("RESOLUTION=%dx%d", info.width, info.height))
	}
	if info.videoRange != "" {
		attrs = append(attrs, "VIDEO-RANGE="+info.videoRange)
	}
	return []byte("#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-INDEPENDENT-SEGMENTS\n#EXT-X-STREAM-INF:" +
		strings.Join(attrs, ",") + "\nindex.m3u8\n")
}

// firstSegmentBandwidth estimates the peak bit rate from the first segment, with headroom.
func firstSegmentBandwidth(dir string, media []byte) int {
	const fallback = 20_000_000
	lines := strings.Split(string(media), "\n")
	for i, l := range lines {
		d, ok := strings.CutPrefix(l, "#EXTINF:")
		if !ok || i+1 >= len(lines) {
			continue
		}
		dur, _ := strconv.ParseFloat(strings.TrimSuffix(strings.TrimSpace(d), ","), 64)
		st, err := os.Stat(filepath.Join(dir, filepath.Base(strings.TrimSpace(lines[i+1]))))
		if err != nil || dur <= 0 {
			return fallback
		}
		return int(float64(st.Size()) * 8 / dur * 1.5)
	}
	return fallback
}

type streamInfo struct {
	codecs        []string
	width, height int
	videoRange    string // "", "PQ" or "HLG"
}

func initInfo(path string) streamInfo {
	var info streamInfo
	b, err := os.ReadFile(path)
	if err != nil {
		return info
	}
	for _, trak := range boxes(child(b, "moov"), "trak") {
		stsd := child(trak, "mdia", "minf", "stbl", "stsd")
		if len(stsd) < 16 {
			continue
		}
		entry := stsd[8:] // version, flags and entry count
		size := int(binary.BigEndian.Uint32(entry))
		if size < 8 || size > len(entry) {
			continue
		}
		kind, body := string(entry[4:8]), entry[8:size]
		switch kind {
		case "avc1", "avc3", "hvc1", "hev1", "dvh1", "dvhe":
			if len(body) < 78 { // VisualSampleEntry fields before its child boxes
				continue
			}
			info.width, info.height = int(binary.BigEndian.Uint16(body[24:])), int(binary.BigEndian.Uint16(body[26:]))
			kids := body[78:]
			if kind[0] == 'a' {
				if c := child(kids, "avcC"); len(c) >= 4 {
					info.codecs = append(info.codecs, fmt.Sprintf("%s.%02x%02x%02x", kind, c[1], c[2], c[3]))
				}
			} else if kind[0] == 'd' {
				if c := dvConfig(kids); len(c) >= 4 {
					info.codecs = append(info.codecs, dvCodec(kind, c))
					info.videoRange = "PQ"
				}
			} else if c := child(kids, "hvcC"); len(c) >= 13 {
				info.codecs = append(info.codecs, hevcCodec(kind, c))
			}
			if colr := child(kids, "colr"); len(colr) >= 8 && string(colr[:4]) == "nclx" {
				switch binary.BigEndian.Uint16(colr[6:]) { // transfer characteristics
				case 16:
					info.videoRange = "PQ"
				case 18:
					info.videoRange = "HLG"
				}
			}
		case "mp4a":
			info.codecs = append(info.codecs, "mp4a.40.2")
		case "ac-3", "ec-3", "fLaC", "Opus", "alac":
			info.codecs = append(info.codecs, kind)
		case ".mp3":
			info.codecs = append(info.codecs, "mp4a.40.34")
		}
	}
	return info
}

// dvConfig returns the Dolby Vision configuration record of a sample entry.
func dvConfig(kids []byte) []byte {
	if c := child(kids, "dvcC"); c != nil {
		return c
	}
	return child(kids, "dvvC")
}

// dvCodec formats a Dolby Vision configuration record, e.g. dvh1.05.06; it holds the profile in 7 bits
// and the level in 6 bits after the version bytes.
func dvCodec(kind string, c []byte) string {
	return fmt.Sprintf("%s.%02d.%02d", kind, c[2]>>1, (c[2]&1)<<5|c[3]>>3)
}

// hevcCodec formats an HEVCDecoderConfigurationRecord as in RFC 6381, e.g. hvc1.2.4.L153.B0.
func hevcCodec(kind string, c []byte) string {
	space := []string{"", "A", "B", "C"}[c[1]>>6]
	tier := "L"
	if c[1]&0x20 != 0 {
		tier = "H"
	}
	compat := bits.Reverse32(binary.BigEndian.Uint32(c[2:6]))
	s := fmt.Sprintf("%s.%s%d.%X.%s%d", kind, space, c[1]&0x1f, compat, tier, c[12])
	cons := c[6:12]
	for len(cons) > 0 && cons[len(cons)-1] == 0 {
		cons = cons[:len(cons)-1]
	}
	for _, x := range cons {
		s += fmt.Sprintf(".%X", x)
	}
	return s
}

// boxes returns the payloads of all top-level boxes of type t in b.
func boxes(b []byte, t string) [][]byte {
	var out [][]byte
	for len(b) >= 8 {
		size := int(binary.BigEndian.Uint32(b))
		if size < 8 || size > len(b) {
			break
		}
		if string(b[4:8]) == t {
			out = append(out, b[8:size])
		}
		b = b[size:]
	}
	return out
}

// child follows a path of box types from b and returns the payload of the last one.
func child(b []byte, path ...string) []byte {
	for _, t := range path {
		found := boxes(b, t)
		if len(found) == 0 {
			return nil
		}
		b = found[0]
	}
	return b
}
