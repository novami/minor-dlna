package library

import (
	"encoding/base64"
	"os"
	"path/filepath"
	"testing"

	"github.com/novami/minor-dlna/internal/config"
)

func testTree(t *testing.T) (*Tree, string) {
	dir := t.TempDir()
	for _, f := range []string{"Ep 10.mkv", "Ep 2.mkv", "notes.txt", ".hidden.mp4", "Season/a.mp4"} {
		p := filepath.Join(dir, f)
		os.MkdirAll(filepath.Dir(p), 0o755)
		os.WriteFile(p, []byte("x"), 0o644)
	}
	return New([]config.Library{{Name: "Filmy", Type: config.Movies, Paths: []string{dir}}}), dir
}

func TestChildren(t *testing.T) {
	tr, _ := testTree(t)
	kids, err := tr.Children("L0")
	if err != nil {
		t.Fatal(err)
	}
	var titles []string
	for _, k := range kids {
		titles = append(titles, k.Title)
	}
	want := []string{"Season", "Ep 2", "Ep 10"}
	if len(titles) != len(want) {
		t.Fatalf("got %v, want %v", titles, want)
	}
	for i := range want {
		if titles[i] != want[i] {
			t.Fatalf("got %v, want %v", titles, want)
		}
	}
	// Round trip: child of a subfolder points back to it, media path resolves.
	sub, _ := tr.Children(kids[0].ID)
	if len(sub) != 1 || sub[0].ParentID != kids[0].ID {
		t.Fatalf("bad subfolder listing %+v", sub)
	}
	if _, err := tr.ResolveMedia(sub[0].MediaPath[len("/media/"):]); err != nil {
		t.Fatal(err)
	}
}

func TestTraversalRejected(t *testing.T) {
	tr, _ := testTree(t)
	for _, rel := range []string{"../etc", "/etc/passwd", "a/../../x"} {
		id := "L0.0:" + base64.RawURLEncoding.EncodeToString([]byte(rel))
		if _, err := tr.Metadata(id); err == nil {
			t.Errorf("%q accepted", rel)
		}
	}
}
