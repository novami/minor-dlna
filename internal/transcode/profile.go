// Package transcode decides how a client can play a file and streams converted media through ffmpeg.
package transcode

import (
	"strings"
)

// Profile describes what a client plays natively. A nil set means "anything".
type Profile struct {
	Name        string
	Containers  set
	VideoCodecs set
	AudioCodecs set
	// Video10Bit reports support for 10-bit H.264 (HEVC/VP9/AV1 10-bit are covered by the codec itself).
	Video10BitH264 bool
}

type set map[string]bool

func newSet(items ...string) set {
	s := set{}
	for _, i := range items {
		s[i] = true
	}
	return s
}

func (s set) has(v string) bool { return s == nil || s[v] }

// Generic plays everything as-is; desktop players handle almost any format.
var Generic = Profile{Name: "generic"}

// LGWebOS22 is LG webOS 22+ (2022 and newer TVs). dts toggles DTS support, which differs by model line.
func LGWebOS22(dts bool) Profile {
	audio := newSet("aac", "ac3", "eac3", "mp3", "mp2", "flac", "vorbis", "opus",
		"pcm_s16le", "pcm_s24le", "pcm_s16be", "pcm_s24be", "pcm_u8")
	if dts {
		audio["dts"] = true
	}
	return Profile{
		Name: "lg-webos22",
		// ffprobe format names (first component, see normalizeContainer).
		Containers:  newSet("matroska", "mov", "mpegts", "avi", "mpeg", "flac", "mp3", "wav", "ogg", "aac"),
		VideoCodecs: newSet("h264", "hevc", "vp9", "av1", "mpeg2video", "mpeg4", "vc1"),
		AudioCodecs: audio,
	}
}

// Detect picks a profile from the client's User-Agent.
func Detect(userAgent string, dts bool) Profile {
	ua := strings.ToLower(userAgent)
	for _, marker := range []string{"lge", "webos", "lg-", "lg "} {
		if strings.Contains(ua, marker) {
			return LGWebOS22(dts)
		}
	}
	return Generic
}

// normalizeContainer maps ffprobe format_name lists ("mov,mp4,m4a,3gp,3g2,mj2", "matroska,webm") to one key.
func normalizeContainer(formatName string) string {
	first, _, _ := strings.Cut(formatName, ",")
	return first
}
