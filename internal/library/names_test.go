package library

import "testing"

func TestParseEpisode(t *testing.T) {
	cases := []struct {
		rel  string
		want Episode
		ok   bool
	}{
		{"Breaking.Point.S01E02.Pilot.1080p.WEB-DL.mkv", Episode{"Breaking Point", 1, 2, "Pilot"}, true},
		{"Moje show/Moje show 2x05.mkv", Episode{"Moje show", 2, 5, ""}, true},
		{"Seriál/Season 3/04 - Návrat.mp4", Episode{"Seriál", 3, 4, "Návrat"}, true},
		{"Seriál/S02/S02E10.mkv", Episode{"Seriál", 2, 10, ""}, true},
		{"Film (2019).mkv", Episode{}, false},
	}
	for _, c := range cases {
		got, ok := ParseEpisode(c.rel)
		if ok != c.ok || got != c.want {
			t.Errorf("%q: got %+v %v, want %+v %v", c.rel, got, ok, c.want, c.ok)
		}
	}
}

func TestParseMovie(t *testing.T) {
	cases := []struct {
		name, title string
		year        int
	}{
		{"Film Name (2019).mkv", "Film Name", 2019},
		{"Film.Name.2019.1080p.x265.mkv", "Film Name", 2019},
		{"2001 A Space Odyssey (1968).mkv", "2001 A Space Odyssey", 1968},
		{"Pelíšky.720p.mkv", "Pelíšky", 0},
		{"Dovolená.mp4", "Dovolená", 0},
	}
	for _, c := range cases {
		title, year := ParseMovie(c.name)
		if title != c.title || year != c.year {
			t.Errorf("%q: got %q %d, want %q %d", c.name, title, year, c.title, c.year)
		}
	}
}

func TestSortKey(t *testing.T) {
	if !(SortKey("Ep 2") < SortKey("Ep 10")) {
		t.Fatal("natural order broken")
	}
}

func TestMatchSubtitle(t *testing.T) {
	srts := []string{"Film.en.srt", "Film.srt", "Film.cz.srt", "Jiný.srt"}
	if got := matchSubtitle("/m/Film.mkv", srts); got != "/m/Film.cz.srt" {
		t.Fatalf("got %q", got)
	}
	if got := matchSubtitle("/m/Film.mkv", []string{"Film.en.srt"}); got != "/m/Film.en.srt" {
		t.Fatalf("got %q", got)
	}
	if got := matchSubtitle("/m/Other.mkv", srts); got != "" {
		t.Fatalf("got %q", got)
	}
}
