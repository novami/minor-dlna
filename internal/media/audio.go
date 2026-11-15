package media

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/dhowden/tag"
)

type AudioMeta struct {
	Title       string
	Artist      string // track artist
	AlbumArtist string // grouping artist (album artist, falls back to track artist)
	Album       string
	Genre       string
	Year        int
	Track       int
	Disc        int
	HasPicture  bool // embedded cover or cover file in the folder
}

var reTrackPrefix = regexp.MustCompile(`^(\d{1,3})[ ._-]+(.+)$`)

// ReadAudio reads tags and fills gaps from the folder layout "Artist/Album/01 Title.ext".
// rel is the path relative to the library root.
func ReadAudio(path, rel string) AudioMeta {
	var m AudioMeta
	if f, err := os.Open(path); err == nil {
		if t, err := tag.ReadFrom(f); err == nil {
			m.Title = strings.TrimSpace(t.Title())
			m.Artist = strings.TrimSpace(t.Artist())
			m.AlbumArtist = strings.TrimSpace(t.AlbumArtist())
			m.Album = strings.TrimSpace(t.Album())
			m.Genre = strings.TrimSpace(t.Genre())
			m.Year = t.Year()
			m.Track, _ = t.Track()
			m.Disc, _ = t.Disc()
			m.HasPicture = t.Picture() != nil && len(t.Picture().Data) > 0
		}
		f.Close()
	}

	base := strings.TrimSuffix(filepath.Base(rel), filepath.Ext(rel))
	if m.Title == "" {
		m.Title = base
		if sm := reTrackPrefix.FindStringSubmatch(base); sm != nil {
			m.Title = sm[2]
			if m.Track == 0 {
				m.Track = atoi(sm[1])
			}
		}
	}
	dirs := strings.Split(filepath.ToSlash(filepath.Dir(rel)), "/")
	if dirs[0] == "." {
		dirs = nil
	}
	if m.Album == "" && len(dirs) >= 1 {
		m.Album = dirs[len(dirs)-1]
	}
	if m.Artist == "" && len(dirs) >= 2 {
		m.Artist = dirs[len(dirs)-2]
	}
	if m.AlbumArtist == "" {
		m.AlbumArtist = m.Artist
	}
	if !m.HasPicture {
		_, m.HasPicture = FolderCover(path)
	}
	return m
}

// AudioPicture returns embedded cover art, if any.
func AudioPicture(path string) ([]byte, bool) {
	f, err := os.Open(path)
	if err != nil {
		return nil, false
	}
	defer f.Close()
	t, err := tag.ReadFrom(f)
	if err != nil || t.Picture() == nil || len(t.Picture().Data) == 0 {
		return nil, false
	}
	return t.Picture().Data, true
}

// FolderCover finds cover.jpg / folder.jpg / front.jpg next to a file.
func FolderCover(path string) (string, bool) {
	dir := filepath.Dir(path)
	entries, err := os.ReadDir(dir)
	if err != nil {
		return "", false
	}
	for _, want := range []string{"cover", "folder", "front", "album"} {
		for _, e := range entries {
			n := strings.ToLower(e.Name())
			ext := filepath.Ext(n)
			if strings.TrimSuffix(n, ext) == want && (ext == ".jpg" || ext == ".jpeg" || ext == ".png") {
				return filepath.Join(dir, e.Name()), true
			}
		}
	}
	return "", false
}

func atoi(s string) int {
	n := 0
	for _, c := range s {
		n = n*10 + int(c-'0')
	}
	return n
}
