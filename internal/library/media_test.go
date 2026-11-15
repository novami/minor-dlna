package library

import (
	"context"
	"image"
	"image/jpeg"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/novami/minor-dlna/internal/config"
	"github.com/novami/minor-dlna/internal/media"
	"github.com/novami/minor-dlna/internal/store"
)

func writeJPEG(t *testing.T, path string, w, h int, mtime time.Time) {
	t.Helper()
	os.MkdirAll(filepath.Dir(path), 0o755)
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := jpeg.Encode(f, image.NewRGBA(image.Rect(0, 0, w, h)), nil); err != nil {
		t.Fatal(err)
	}
	f.Close()
	os.Chtimes(path, mtime, mtime)
}

func TestPhotoAndMusicViews(t *testing.T) {
	ctx := context.Background()
	photos, music := t.TempDir(), t.TempDir()
	may := time.Date(2023, 5, 10, 12, 0, 0, 0, time.Local)
	writeJPEG(t, filepath.Join(photos, "Dovolená/a.jpg"), 300, 200, may)
	writeJPEG(t, filepath.Join(photos, "b.jpg"), 10, 10, time.Date(2021, 1, 2, 0, 0, 0, 0, time.Local))
	touch(t, music, "Kapela/Album Jedna/02 Druhá.mp3", "Kapela/Album Jedna/01 První.mp3", "Jiný/Deska/01 Song.flac")
	writeJPEG(t, filepath.Join(music, "Kapela/Album Jedna/cover.jpg"), 20, 20, may)

	st, err := store.Open(filepath.Join(t.TempDir(), "db.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	cat, err := NewCatalog(ctx, st, []config.Library{
		{Name: "Fotky", Type: config.Photos, Paths: []string{photos}},
		{Name: "Hudba", Type: config.Music, Paths: []string{music}},
	})
	if err != nil {
		t.Fatal(err)
	}
	sc := NewScanner(cat, media.NewProber("/nonexistent"))
	for _, l := range cat.Libraries() {
		if _, err := sc.ScanLibrary(ctx, l); err != nil {
			t.Fatal(err)
		}
	}
	pid, mid := libID(cat.Libraries()[0]), libID(cat.Libraries()[1])

	years, _, _ := cat.Children(ctx, pid+"/dates", 0, 0)
	eq(t, years, "2023", "2021")
	monthsList, _, _ := cat.Children(ctx, years[0].ID, 0, 0)
	eq(t, monthsList, "Květen 2023")
	pics, _, _ := cat.Children(ctx, monthsList[0].ID, 0, 0)
	eq(t, pics, "a")
	if pics[0].Width != 300 || pics[0].ArtPath == "" || !pics[0].Taken.Equal(may) {
		t.Fatalf("photo object %+v", pics[0])
	}
	if md, err := cat.Metadata(ctx, monthsList[0].ID); err != nil || md.ParentID != years[0].ID {
		t.Fatalf("month metadata %+v %v", md, err)
	}

	artists, _, _ := cat.Children(ctx, mid+"/artists", 0, 0)
	eq(t, artists, "Jiný", "Kapela")
	albums, _, _ := cat.Children(ctx, artists[1].ID, 0, 0)
	eq(t, albums, "Album Jedna")
	if albums[0].ArtPath == "" || albums[0].Class != classAlbum {
		t.Fatalf("album without art/class: %+v", albums[0])
	}
	tracks, _, _ := cat.Children(ctx, albums[0].ID, 0, 0)
	eq(t, tracks, "První", "Druhá")
	if tracks[0].Track != 1 || tracks[0].Artist != "Kapela" || tracks[0].Album != "Album Jedna" {
		t.Fatalf("track %+v", tracks[0])
	}
	all, _, _ := cat.Children(ctx, mid+"/albums", 0, 0)
	eq(t, all, "Album Jedna", "Deska")
	if all[1].ArtPath != "" {
		t.Fatal("album without cover has art")
	}
}
