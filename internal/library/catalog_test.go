package library

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/novami/minor-dlna/internal/config"
	"github.com/novami/minor-dlna/internal/media"
	"github.com/novami/minor-dlna/internal/store"
)

func touch(t *testing.T, root string, files ...string) {
	t.Helper()
	for _, f := range files {
		p := filepath.Join(root, f)
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
}

func titles(objs []Object) []string {
	var out []string
	for _, o := range objs {
		out = append(out, o.Title)
	}
	return out
}

func eq(t *testing.T, got []Object, want ...string) {
	t.Helper()
	g := titles(got)
	if len(g) != len(want) {
		t.Fatalf("got %q, want %q", g, want)
	}
	for i := range want {
		if g[i] != want[i] {
			t.Fatalf("got %q, want %q", g, want)
		}
	}
}

func TestCatalogScanAndViews(t *testing.T) {
	ctx := context.Background()
	movies, shows := t.TempDir(), t.TempDir()
	touch(t, movies, "Zeta (2001).mkv", "Alfa.2019.1080p.mkv", "Sub/Beta (2019).mp4", "readme.txt", ".hidden/x.mkv")
	touch(t, shows, "Show A/Season 1/S01E02 Druhý.mkv", "Show A/Season 1/S01E10.mkv", "Show A/Season 2/S02E01.mkv")

	st, err := store.Open(filepath.Join(t.TempDir(), "db.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	cat, err := NewCatalog(ctx, st, []config.Library{
		{Name: "Filmy", Type: config.Movies, Paths: []string{movies}},
		{Name: "Seriály", Type: config.Shows, Paths: []string{shows}},
	})
	if err != nil {
		t.Fatal(err)
	}
	sc := NewScanner(cat, media.NewProber("/nonexistent"))
	for _, l := range cat.Libraries() {
		if st, err := sc.ScanLibrary(ctx, l); err != nil || !st.changed() {
			t.Fatalf("scan %s: %+v %v", l.Name, st, err)
		}
	}
	mid, sid := libID(cat.Libraries()[0]), libID(cat.Libraries()[1])

	all, total, err := cat.Children(ctx, mid+"/all", 0, 0)
	if err != nil || total != 3 {
		t.Fatalf("all: %d %v", total, err)
	}
	eq(t, all, "Alfa (2019)", "Beta (2019)", "Zeta (2001)")

	// Paging.
	p, total, _ := cat.Children(ctx, mid+"/all", 1, 1)
	if total != 3 {
		t.Fatalf("total %d", total)
	}
	eq(t, p, "Beta (2019)")

	years, _, _ := cat.Children(ctx, mid+"/years", 0, 0)
	eq(t, years, "2019", "2001")
	y, _, _ := cat.Children(ctx, years[0].ID, 0, 0)
	eq(t, y, "Alfa (2019)", "Beta (2019)")

	folders, _, _ := cat.Children(ctx, mid+"/folders", 0, 0)
	eq(t, folders, "Sub", "Alfa (2019)", "Zeta (2001)")
	if md, err := cat.Metadata(ctx, folders[0].ID); err != nil || md.ParentID != mid+"/folders" || md.ChildCount != 1 {
		t.Fatalf("folder metadata %+v %v", md, err)
	}

	showList, _, _ := cat.Children(ctx, sid+"/shows", 0, 0)
	eq(t, showList, "Show A")
	seasons, _, _ := cat.Children(ctx, showList[0].ID, 0, 0)
	eq(t, seasons, "Série 1", "Série 2")
	eps, _, _ := cat.Children(ctx, seasons[0].ID, 0, 0)
	eq(t, eps, "02. Druhý", "10.")

	// Media URL resolves to the file.
	item, err := cat.ResolveMedia(ctx, eps[0].MediaPath[len("/media/"):])
	if err != nil || filepath.Base(item.Path) != "S01E02 Druhý.mkv" {
		t.Fatalf("resolve: %+v %v", item, err)
	}

	// A second scan keeps items in nested folders (parents must not be pruned).
	if st, err := sc.ScanLibrary(ctx, cat.Libraries()[1]); err != nil || st.changed() {
		t.Fatalf("rescan changed something: %+v %v", st, err)
	}
	if eps, _, _ := cat.Children(ctx, seasons[0].ID, 0, 0); len(eps) != 2 {
		t.Fatalf("episodes lost on rescan: %d", len(eps))
	}

	// Removal is picked up and empty folders disappear.
	os.RemoveAll(filepath.Join(movies, "Sub"))
	if !sc.needsScan(cat.Libraries()[0]) {
		t.Fatal("change not detected")
	}
	if st, _ := sc.ScanLibrary(ctx, cat.Libraries()[0]); st.removed != 1 {
		t.Fatalf("removed %d", st.removed)
	}
	folders, _, _ = cat.Children(ctx, mid+"/folders", 0, 0)
	eq(t, folders, "Alfa (2019)", "Zeta (2001)")
	if _, err := cat.Metadata(ctx, "I999"); err == nil {
		t.Fatal("unknown item found")
	}
}
