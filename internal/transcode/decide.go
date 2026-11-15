package transcode

import (
	"strings"
)

// Media is what the decision needs to know about a file (from ffprobe).
type Media struct {
	Audio      bool // audio-only file
	Container  string
	VideoCodec string
	AudioCodec string
	PixFmt     string
	Channels   int
}

// Plan says how to deliver a file. The zero value is direct play.
//
// Plans are encoded into the stream URL (Key) so the streaming request does not depend on
// the User-Agent of whichever player component fetches it.
type Plan struct {
	Video string // "" no change/none, "copy", "h264"
	Audio string // "" no change/none, "copy", "aac", "ac3", "flac"
}

func (p Plan) Direct() bool { return p == Plan{} }

// Key encodes the plan for URLs, e.g. "copy-ac3".
func (p Plan) Key() string { return orDash(p.Video) + "-" + orDash(p.Audio) }

func orDash(s string) string {
	if s == "" {
		return "x"
	}
	return s
}

var (
	validVideo = newSet("x", "copy", "h264")
	validAudio = newSet("x", "copy", "aac", "ac3", "flac")
)

// ParseKey accepts only known values, so URL input never reaches ffmpeg arguments directly.
func ParseKey(k string) (Plan, bool) {
	v, a, ok := strings.Cut(k, "-")
	if !ok || !validVideo[v] || !validAudio[a] || (v == "x" && a == "x") {
		return Plan{}, false
	}
	p := Plan{Video: v, Audio: a}
	if v == "x" {
		p.Video = ""
	}
	if a == "x" {
		p.Audio = ""
	}
	return p, true
}

// Decide chooses direct play when possible, otherwise the cheapest conversion.
func Decide(p Profile, m Media) Plan {
	// Unknown details (no ffprobe or probe failed): try direct play rather than guessing.
	if m.Container == "" || (!m.Audio && m.VideoCodec == "") {
		return Plan{}
	}
	containerOK := p.Containers.has(normalizeContainer(m.Container))
	audioOK := m.AudioCodec == "" || p.AudioCodecs.has(m.AudioCodec)

	if m.Audio {
		if containerOK && audioOK {
			return Plan{}
		}
		return Plan{Audio: "flac"}
	}

	videoOK := p.VideoCodecs.has(m.VideoCodec)
	if m.VideoCodec == "h264" && is10Bit(m.PixFmt) && !p.Video10BitH264 && p.VideoCodecs != nil {
		videoOK = false
	}
	if containerOK && videoOK && audioOK {
		return Plan{}
	}

	plan := Plan{Video: "copy", Audio: "copy"}
	// MPEG-TS cannot carry VP9/AV1, so those are re-encoded when remuxing is needed.
	if !videoOK || m.VideoCodec == "vp9" || m.VideoCodec == "av1" {
		plan.Video = "h264"
	}
	if m.AudioCodec == "" {
		plan.Audio = ""
	} else if !audioOK || !tsAudio[m.AudioCodec] {
		plan.Audio = "aac"
		if m.Channels > 2 {
			plan.Audio = "ac3" // keeps 5.1
		}
	}
	return plan
}

// tsAudio are codecs MPEG-TS can carry when copying.
var tsAudio = newSet("aac", "ac3", "eac3", "mp3", "mp2", "dts")

func is10Bit(pixFmt string) bool {
	return strings.Contains(pixFmt, "10") || strings.Contains(pixFmt, "12")
}
