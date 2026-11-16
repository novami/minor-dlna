package metadata

import (
	"strings"
	"unicode"

	"golang.org/x/text/unicode/norm"
)

// Title similarity scores.
const (
	hit    = 1.0 // returned by the search
	prefix = 1.5 // the name starts with the title, e.g. "Film 3" vs "Film 3: Subtitle"
	exact  = 2.0 // same title, ignoring case, accents and punctuation
)

// normalize lower-cases, drops accents and turns punctuation into single spaces.
func normalize(s string) string {
	var b strings.Builder
	space := false
	for _, r := range norm.NFD.String(strings.ToLower(s)) {
		switch {
		case unicode.Is(unicode.Mn, r):
		case unicode.IsLetter(r) || unicode.IsDigit(r):
			if space && b.Len() > 0 {
				b.WriteByte(' ')
			}
			space = false
			b.WriteRune(r)
		default:
			space = true
		}
	}
	return b.String()
}

func similarity(title string, names []string) float64 {
	q := normalize(title)
	// "Film 1" is usually just "Film".
	alt := strings.TrimSuffix(q, " 1")
	best := hit
	for _, n := range names {
		n = normalize(n)
		switch {
		case n == "":
		case n == q || n == alt:
			return exact
		case strings.HasPrefix(n, q+" "):
			best = prefix
		}
	}
	return best
}

// choose picks the candidate a file name means, or nothing when it is not clear.
func choose(title string, year int, cands []Candidate) (Candidate, bool) {
	type scored struct {
		c            Candidate
		title, total float64
	}
	var ok []scored
	for _, c := range cands {
		s := scored{c: c, title: similarity(title, append([]string{c.Title}, c.matched...))}
		s.total = s.title
		if year > 0 && c.Year > 0 {
			switch d := c.Year - year; {
			case d == 0:
				s.total += 2
			case d == 1 || d == -1:
				s.total++
			default:
				continue
			}
		}
		ok = append(ok, s)
	}
	if len(ok) == 0 {
		return Candidate{}, false
	}
	best, tie := ok[0], false
	for _, s := range ok[1:] {
		switch {
		case s.total > best.total:
			best, tie = s, false
		case s.total == best.total:
			tie = true
		}
	}
	if tie {
		return Candidate{}, false
	}
	near := 0
	for _, s := range ok {
		if s.title >= prefix {
			near++
		}
	}
	accept := best.total >= 3 || best.title == exact || (near == 1 && best.title >= prefix)
	return best.c, accept
}
