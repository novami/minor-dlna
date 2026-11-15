package media

import (
	"context"
	"image"
	_ "image/gif"
	_ "image/jpeg"
	_ "image/png"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/rwcarlsen/goexif/exif"
)

// sips ships with macOS and decodes HEIC through the system image framework.
const sipsBin = "/usr/bin/sips"

type PhotoMeta struct {
	Taken       time.Time // zero if unknown
	Width       int
	Height      int
	Orientation int // EXIF 1..8, 0 = unknown
}

// IsHEIF reports whether a file needs the system converter.
func IsHEIF(path string) bool {
	switch strings.ToLower(filepath.Ext(path)) {
	case ".heic", ".heif":
		return true
	}
	return false
}

// ReadPhoto extracts date, size and orientation. Dimensions are as stored (before rotation).
func ReadPhoto(ctx context.Context, path string) (PhotoMeta, error) {
	if IsHEIF(path) {
		return readHEIF(ctx, path)
	}
	f, err := os.Open(path)
	if err != nil {
		return PhotoMeta{}, err
	}
	defer f.Close()
	var m PhotoMeta
	if cfg, _, err := image.DecodeConfig(f); err == nil {
		m.Width, m.Height = cfg.Width, cfg.Height
	}
	if _, err := f.Seek(0, 0); err != nil {
		return m, nil
	}
	if x, err := exif.Decode(f); err == nil {
		if t, err := x.DateTime(); err == nil && t.Year() > 1900 {
			m.Taken = t
		}
		if tag, err := x.Get(exif.Orientation); err == nil {
			if v, err := tag.Int(0); err == nil {
				m.Orientation = v
			}
		}
	}
	return m, nil
}

// ReadOrientation returns the EXIF orientation of a JPEG, or 1.
func ReadOrientation(path string) int {
	f, err := os.Open(path)
	if err != nil {
		return 1
	}
	defer f.Close()
	x, err := exif.Decode(f)
	if err != nil {
		return 1
	}
	tag, err := x.Get(exif.Orientation)
	if err != nil {
		return 1
	}
	v, err := tag.Int(0)
	if err != nil || v < 1 || v > 8 {
		return 1
	}
	return v
}

var reSipsProp = regexp.MustCompile(`(?m)^\s+(\w+): (.+)$`)

func readHEIF(ctx context.Context, path string) (PhotoMeta, error) {
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, sipsBin, "-g", "pixelWidth", "-g", "pixelHeight", "-g", "creation", path).Output()
	if err != nil {
		return PhotoMeta{}, err
	}
	var m PhotoMeta
	for _, p := range reSipsProp.FindAllStringSubmatch(string(out), -1) {
		switch p[1] {
		case "pixelWidth":
			m.Width, _ = strconv.Atoi(p[2])
		case "pixelHeight":
			m.Height, _ = strconv.Atoi(p[2])
		case "creation":
			if t, err := time.ParseInLocation("2006:01:02 15:04:05", p[2], time.Local); err == nil {
				m.Taken = t
			}
		}
	}
	return m, nil
}
