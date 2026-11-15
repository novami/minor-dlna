// Package thumbs generates and caches JPEG thumbnails and TV-sized photo renditions.
package thumbs

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"image"
	"image/jpeg"
	"io"
	"log/slog"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"golang.org/x/image/draw"

	"github.com/novami/minor-dlna/internal/dlna"
	"github.com/novami/minor-dlna/internal/library"
	"github.com/novami/minor-dlna/internal/media"
)

// Size is a DLNA JPEG profile with its bounding box (landscape; portrait swaps).
type Size struct {
	Name    string
	Profile string
	W, H    int
}

var sizes = map[string]Size{
	"tn":  {"tn", "JPEG_TN", 160, 160},
	"sm":  {"sm", "JPEG_SM", 640, 480},
	"lrg": {"lrg", "JPEG_LRG", 4096, 4096},
}

func Lookup(name string) (Size, bool) {
	s, ok := sizes[name]
	return s, ok
}

var errNoSource = errors.New("no image source")

type Service struct {
	dir    string
	ffmpeg string
	cat    *library.Catalog

	sem   chan struct{} // limits concurrent decodes (large photos need a lot of memory)
	mu    sync.Mutex
	locks map[string]*sync.Mutex
}

// New creates the service; ffmpeg may be empty (no video thumbnails).
func New(dir, ffmpeg string, cat *library.Catalog) *Service {
	return &Service{dir: dir, ffmpeg: ffmpeg, cat: cat, sem: make(chan struct{}, 2), locks: map[string]*sync.Mutex{}}
}

// FindFFmpeg looks for ffmpeg in PATH and common Homebrew locations.
func FindFFmpeg() string {
	if p, err := exec.LookPath("ffmpeg"); err == nil {
		return p
	}
	for _, c := range []string{"/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"} {
		if _, err := os.Stat(c); err == nil {
			return c
		}
	}
	return ""
}

// ServeHTTP handles /thumb/{id}/{size}.jpg.
func (s *Service) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	idStr, file, _ := strings.Cut(strings.TrimPrefix(r.URL.Path, "/thumb/"), "/")
	size, ok := Lookup(strings.TrimSuffix(file, ".jpg"))
	id, err := strconv.ParseInt(idStr, 10, 64)
	if !ok || err != nil {
		http.NotFound(w, r)
		return
	}
	o, err := s.cat.Metadata(r.Context(), "I"+idStr)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	path, err := s.Get(r.Context(), id, o, size)
	if err != nil {
		if !errors.Is(err, errNoSource) && r.Context().Err() == nil {
			slog.Debug("thumbnail failed", "item", id, "size", size.Name, "err", err)
		}
		http.NotFound(w, r)
		return
	}
	f, err := os.Open(path)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	defer f.Close()
	fi, _ := f.Stat()
	h := w.Header()
	h.Set("Content-Type", "image/jpeg")
	h.Set("Cache-Control", "max-age=86400")
	h["transferMode.dlna.org"] = []string{"Interactive"}
	if r.Header.Get("getcontentFeatures.dlna.org") == "1" {
		h["contentFeatures.dlna.org"] = []string{ContentFeatures(size)}
	}
	http.ServeContent(w, r, "", fi.ModTime(), f)
}

// ContentFeatures is the protocolInfo 4th field for a generated rendition.
func ContentFeatures(size Size) string {
	return "DLNA.ORG_PN=" + size.Profile + ";DLNA.ORG_OP=01;DLNA.ORG_CI=1;DLNA.ORG_FLAGS=00D00000000000000000000000000000"
}

// ServesOriginal reports whether the "lrg" rendition is the untouched original file.
func ServesOriginal(o library.Object) bool {
	return o.Format.Mime == "image/jpeg" && o.Width > 0 && o.Width <= 4096 && o.Height <= 4096 && o.Orientation <= 1
}

// Get returns the path of the rendition, generating it if needed.
func (s *Service) Get(ctx context.Context, id int64, o library.Object, size Size) (string, error) {
	if size.Name == "lrg" && ServesOriginal(o) {
		return o.Path, nil
	}
	// Key includes mtime and size: a changed file gets a fresh rendition.
	key := fmt.Sprintf("%d-%s-%d-%d", id, size.Name, o.ModTime.Unix(), o.Size)
	dst := filepath.Join(s.dir, shard(id), key+".jpg")
	if _, err := os.Stat(dst); err == nil {
		return dst, nil
	}
	if _, err := os.Stat(dst + ".fail"); err == nil {
		return "", errNoSource
	}

	lock := s.lock(key)
	lock.Lock()
	defer lock.Unlock()
	if _, err := os.Stat(dst); err == nil {
		return dst, nil
	}

	select {
	case s.sem <- struct{}{}:
		defer func() { <-s.sem }()
	case <-ctx.Done():
		return "", ctx.Err()
	}
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return "", err
	}
	s.purgeVariants(id, size.Name)
	err := s.generate(ctx, o, size, dst)
	if errors.Is(err, errNoSource) || (err != nil && ctx.Err() == nil) {
		// Remember failures so a broken file doesn't spawn a converter on every request.
		_ = os.WriteFile(dst+".fail", nil, 0o644)
	}
	if err != nil {
		return "", err
	}
	return dst, nil
}

func (s *Service) generate(ctx context.Context, o library.Object, size Size, dst string) error {
	switch o.Format.Kind {
	case dlna.Image:
		if media.IsHEIF(o.Path) {
			return s.fromSips(ctx, o, size, dst)
		}
		f, err := os.Open(o.Path)
		if err != nil {
			return err
		}
		defer f.Close()
		return encodeFrom(f, o.Orientation, size, dst)
	case dlna.Audio:
		if data, ok := media.AudioPicture(o.Path); ok {
			if err := encodeFrom(bytes.NewReader(data), 1, size, dst); err == nil {
				return nil
			}
		}
		if cover, ok := media.FolderCover(o.Path); ok {
			f, err := os.Open(cover)
			if err != nil {
				return err
			}
			defer f.Close()
			return encodeFrom(f, media.ReadOrientation(cover), size, dst)
		}
		return errNoSource
	case dlna.Video:
		return s.fromVideo(ctx, o, size, dst)
	}
	return errNoSource
}

// fromSips converts HEIC with the system converter, then fixes orientation if the output still carries it.
func (s *Service) fromSips(ctx context.Context, o library.Object, size Size, dst string) error {
	ctx, cancel := context.WithTimeout(ctx, time.Minute)
	defer cancel()
	tmp := dst + ".sips.jpg"
	defer os.Remove(tmp)
	// sips -Z also upscales, so never ask for more than the original long side.
	z := max(size.W, size.H)
	if o.Width > 0 {
		z = min(z, max(o.Width, o.Height))
	}
	out, err := exec.CommandContext(ctx, "/usr/bin/sips", "-s", "format", "jpeg", "-s", "formatOptions", "85",
		"-Z", strconv.Itoa(z), o.Path, "--out", tmp).CombinedOutput()
	if err != nil {
		return fmt.Errorf("sips: %v: %s", err, bytes.TrimSpace(out))
	}
	f, err := os.Open(tmp)
	if err != nil {
		return err
	}
	defer f.Close()
	return encodeFrom(f, media.ReadOrientation(tmp), size, dst)
}

func (s *Service) fromVideo(ctx context.Context, o library.Object, size Size, dst string) error {
	if s.ffmpeg == "" {
		return errNoSource
	}
	ctx, cancel := context.WithTimeout(ctx, time.Minute)
	defer cancel()
	// A frame at 10 % skips intros and black opening frames.
	seek := 30.0
	if o.DurationMs > 0 {
		seek = float64(o.DurationMs) / 10000
	}
	box := fmt.Sprintf("scale=w=%d:h=%d:force_original_aspect_ratio=decrease", size.W, size.H)
	tmp := dst + ".tmp"
	for _, ss := range []float64{seek, 0} {
		cmd := exec.CommandContext(ctx, s.ffmpeg, "-nostdin", "-v", "error", "-ss", strconv.FormatFloat(ss, 'f', 1, 64),
			"-i", o.Path, "-frames:v", "1", "-vf", box, "-q:v", "4", "-f", "image2", "-y", tmp)
		if out, err := cmd.CombinedOutput(); err != nil {
			slog.Debug("ffmpeg thumbnail", "path", o.Path, "err", err, "out", string(bytes.TrimSpace(out)))
			continue
		}
		if fi, err := os.Stat(tmp); err == nil && fi.Size() > 0 {
			return os.Rename(tmp, dst)
		}
	}
	os.Remove(tmp)
	return errNoSource
}

// encodeFrom decodes an image, applies EXIF orientation, fits it into the box and writes a JPEG atomically.
func encodeFrom(r io.Reader, orientation int, size Size, dst string) error {
	img, _, err := image.Decode(r)
	if err != nil {
		return err
	}
	// Scale first (the box is symmetric under rotation), then rotate the small image.
	img = Fit(img, size)
	img = Orient(img, orientation)
	tmp := dst + ".tmp"
	f, err := os.Create(tmp)
	if err != nil {
		return err
	}
	if err := jpeg.Encode(f, img, &jpeg.Options{Quality: 85}); err != nil {
		f.Close()
		os.Remove(tmp)
		return err
	}
	if err := f.Close(); err != nil {
		os.Remove(tmp)
		return err
	}
	return os.Rename(tmp, dst)
}

// Fit scales an image down to fit the size box (box rotated for portrait images). Never upscales.
func Fit(img image.Image, size Size) image.Image {
	b := img.Bounds()
	w, h := b.Dx(), b.Dy()
	bw, bh := size.W, size.H
	if h > w {
		bw, bh = bh, bw
	}
	if w <= bw && h <= bh {
		return img
	}
	scale := min(float64(bw)/float64(w), float64(bh)/float64(h))
	nw, nh := max(1, int(float64(w)*scale+0.5)), max(1, int(float64(h)*scale+0.5))
	dst := image.NewRGBA(image.Rect(0, 0, nw, nh))
	draw.CatmullRom.Scale(dst, dst.Bounds(), img, b, draw.Src, nil)
	return dst
}

// Orient applies an EXIF orientation (1..8) so the image displays upright.
func Orient(img image.Image, o int) image.Image {
	if o <= 1 || o > 8 {
		return img
	}
	b := img.Bounds()
	w, h := b.Dx(), b.Dy()
	ow, oh := w, h
	if o >= 5 {
		ow, oh = h, w
	}
	dst := image.NewRGBA(image.Rect(0, 0, ow, oh))
	for y := range h {
		for x := range w {
			var dx, dy int
			switch o {
			case 2:
				dx, dy = w-1-x, y
			case 3:
				dx, dy = w-1-x, h-1-y
			case 4:
				dx, dy = x, h-1-y
			case 5:
				dx, dy = y, x
			case 6:
				dx, dy = h-1-y, x
			case 7:
				dx, dy = h-1-y, w-1-x
			case 8:
				dx, dy = y, w-1-x
			}
			dst.Set(dx, dy, img.At(b.Min.X+x, b.Min.Y+y))
		}
	}
	return dst
}

// Purge removes cached renditions of deleted items.
func (s *Service) Purge(ids []int64) {
	for _, id := range ids {
		matches, _ := filepath.Glob(filepath.Join(s.dir, shard(id), strconv.FormatInt(id, 10)+"-*"))
		for _, m := range matches {
			os.Remove(m)
		}
	}
}

func (s *Service) purgeVariants(id int64, size string) {
	matches, _ := filepath.Glob(filepath.Join(s.dir, shard(id), strconv.FormatInt(id, 10)+"-"+size+"-*"))
	for _, m := range matches {
		os.Remove(m)
	}
}

func shard(id int64) string { return fmt.Sprintf("%02x", id%256) }

func (s *Service) lock(key string) *sync.Mutex {
	s.mu.Lock()
	defer s.mu.Unlock()
	l, ok := s.locks[key]
	if !ok {
		l = &sync.Mutex{}
		s.locks[key] = l
	}
	return l
}
