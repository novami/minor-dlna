package metadata

import "testing"

func TestChoose(t *testing.T) {
	cands := []Candidate{
		{ID: "Q1", Title: "Červená Karkulka", Year: 1962},
		{ID: "Q2", Title: "Červená Karkulka", Year: 2011},
		{ID: "Q3", Title: "V zajetí démonů 3: Na Ďáblův příkaz", Year: 2021},
	}
	tests := []struct {
		title string
		year  int
		want  string
	}{
		{"Cervena Karkulka", 2011, "Q2"},
		{"Červená Karkulka", 0, ""}, // two films of that name, no year: unsure
		{"Červená Karkulka", 1990, ""},
		{"v zajeti demonu 3", 0, "Q3"},
	}
	for _, tt := range tests {
		c, ok := choose(tt.title, tt.year, cands)
		if got := map[bool]string{true: c.ID}[ok]; got != tt.want {
			t.Errorf("choose(%q, %d) = %q, want %q", tt.title, tt.year, got, tt.want)
		}
	}
}
