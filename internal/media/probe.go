// Package media reads technical metadata from media files.
package media

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"strconv"
	"time"
)

var ErrNoProbe = errors.New("ffprobe not found")

type Info struct {
	DurationMs int64
	Bitrate    int64
	Container  string
	VideoCodec string
	AudioCodec string
	Width      int
	Height     int
	PixFmt     string
	Channels   int
}

type Prober struct {
	bin string
}

// NewProber finds ffprobe in PATH or common Homebrew locations. bin may be empty.
func NewProber(bin string) *Prober {
	if bin == "" {
		if p, err := exec.LookPath("ffprobe"); err == nil {
			bin = p
		} else {
			for _, c := range []string{"/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe"} {
				if _, err := os.Stat(c); err == nil {
					bin = c
					break
				}
			}
		}
	}
	return &Prober{bin: bin}
}

func (p *Prober) Available() bool { return p.bin != "" }

type probeJSON struct {
	Format struct {
		FormatName string `json:"format_name"`
		Duration   string `json:"duration"`
		BitRate    string `json:"bit_rate"`
	} `json:"format"`
	Streams []struct {
		CodecType   string `json:"codec_type"`
		CodecName   string `json:"codec_name"`
		Width       int    `json:"width"`
		Height      int    `json:"height"`
		PixFmt      string `json:"pix_fmt"`
		Channels    int    `json:"channels"`
		Disposition struct {
			AttachedPic int `json:"attached_pic"`
		} `json:"disposition"`
	} `json:"streams"`
}

func (p *Prober) Probe(ctx context.Context, path string) (Info, error) {
	if p.bin == "" {
		return Info{}, ErrNoProbe
	}
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, p.bin, "-v", "error", "-print_format", "json", "-show_format", "-show_streams", path).Output()
	if err != nil {
		return Info{}, err
	}
	var j probeJSON
	if err := json.Unmarshal(out, &j); err != nil {
		return Info{}, err
	}
	var info Info
	if d, err := strconv.ParseFloat(j.Format.Duration, 64); err == nil {
		info.DurationMs = int64(d * 1000)
	}
	info.Bitrate, _ = strconv.ParseInt(j.Format.BitRate, 10, 64)
	info.Container = j.Format.FormatName
	for _, s := range j.Streams {
		switch {
		case s.CodecType == "video" && s.Disposition.AttachedPic == 0 && info.VideoCodec == "":
			info.VideoCodec, info.Width, info.Height, info.PixFmt = s.CodecName, s.Width, s.Height, s.PixFmt
		case s.CodecType == "audio" && info.AudioCodec == "":
			info.AudioCodec, info.Channels = s.CodecName, s.Channels
		}
	}
	return info, nil
}
