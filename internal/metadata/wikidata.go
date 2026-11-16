package metadata

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strconv"
	"strings"
)

const (
	wikidataAPI = "https://www.wikidata.org/w/api.php"
	userAgent   = "MinorDLNA (https://github.com/novami/minor-dlna)"
)

// Kind is the library type the metadata is for.
type Kind string

const (
	Movie Kind = "movies"
	Show  Kind = "shows"
)

// Wikidata classes accepted as a movie or a show, besides an entity with a TMDb ID of the right type.
var classes = map[Kind]map[string]bool{
	Movie: {"Q11424": true, "Q24862": true, "Q506240": true, "Q202866": true, "Q229390": true},
	Show:  {"Q5398426": true, "Q1259759": true, "Q581714": true, "Q117467246": true, "Q15416": true},
}

var tmdbProp = map[Kind]string{Movie: "P4947", Show: "P4983"}

// Candidate is a search hit of the requested kind.
type Candidate struct {
	ID          string `json:"id"` // Wikidata Q-ID
	Title       string `json:"title"`
	Description string `json:"description"`
	Year        int    `json:"year"`
	matched     []string
}

// Details is what gets stored for a matched movie or show.
type Details struct {
	Wikidata, TMDb   string
	Title, OrigTitle string
	Year             int
	Overview         string
	Genres           []string
	Director         string
	Cast             []string
	Runtime          int // minutes
	Rating           float64
	PosterURL        string
}

type client struct {
	http *http.Client
}

func (c *client) getJSON(ctx context.Context, u string, header http.Header, v any) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return err
	}
	req.Header.Set("User-Agent", userAgent)
	for k, vs := range header {
		req.Header[k] = vs
	}
	resp, err := c.http.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusNotFound {
		return errNotFound
	}
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("%s: HTTP %d", req.URL.Host, resp.StatusCode)
	}
	return json.NewDecoder(resp.Body).Decode(v)
}

type entity struct {
	Labels       map[string]struct{ Value string } `json:"labels"`
	Descriptions map[string]struct{ Value string } `json:"descriptions"`
	Sitelinks    map[string]struct{ Title string } `json:"sitelinks"`
	Claims       map[string][]struct {
		Mainsnak struct {
			Datavalue struct {
				Value json.RawMessage `json:"value"`
			} `json:"datavalue"`
		} `json:"mainsnak"`
		Rank string `json:"rank"`
	} `json:"claims"`
}

func (e *entity) label() string {
	for _, l := range []string{"cs", "mul", "en"} {
		if v := e.Labels[l].Value; v != "" {
			return v
		}
	}
	return ""
}

// values decodes the claim values of a property into T, skipping deprecated statements.
func values[T any](e *entity, prop string) []T {
	var out []T
	for _, c := range e.Claims[prop] {
		var v T
		if c.Rank != "deprecated" && json.Unmarshal(c.Mainsnak.Datavalue.Value, &v) == nil {
			out = append(out, v)
		}
	}
	return out
}

func (e *entity) ids(prop string) []string {
	var out []string
	for _, v := range values[struct{ ID string }](e, prop) {
		out = append(out, v.ID)
	}
	return out
}

func (e *entity) str(prop string) string {
	if v := values[string](e, prop); len(v) > 0 {
		return v[0]
	}
	return ""
}

// year is the earliest year of the publication (or start) dates.
func (e *entity) year() int {
	best := 0
	for _, prop := range []string{"P577", "P580"} {
		for _, v := range values[struct{ Time string }](e, prop) {
			if len(v.Time) >= 5 {
				if y, err := strconv.Atoi(v.Time[1:5]); err == nil && y > 0 && (best == 0 || y < best) {
					best = y
				}
			}
		}
	}
	return best
}

func (e *entity) is(k Kind) bool {
	if e.str(tmdbProp[k]) != "" {
		return true
	}
	for _, id := range e.ids("P31") {
		if classes[k][id] {
			return true
		}
	}
	return false
}

func (c *client) entities(ctx context.Context, ids []string, props string) (map[string]*entity, error) {
	q := url.Values{"action": {"wbgetentities"}, "ids": {strings.Join(ids, "|")}, "props": {props},
		"languages": {"cs|mul|en"}, "sitefilter": {"cswiki|enwiki"}, "format": {"json"}}
	var r struct{ Entities map[string]*entity }
	if err := c.getJSON(ctx, wikidataAPI+"?"+q.Encode(), nil, &r); err != nil {
		return nil, err
	}
	return r.Entities, nil
}

// search finds movies or shows by title; Czech labels, missing accents are tolerated.
func (c *client) search(ctx context.Context, k Kind, title string) ([]Candidate, error) {
	q := url.Values{"action": {"wbsearchentities"}, "search": {title}, "language": {"cs"}, "uselang": {"cs"},
		"type": {"item"}, "limit": {"12"}, "format": {"json"}}
	var r struct {
		Search []struct {
			ID          string
			Description string
			Match       struct{ Text string }
		}
	}
	if err := c.getJSON(ctx, wikidataAPI+"?"+q.Encode(), nil, &r); err != nil {
		return nil, err
	}
	var ids []string
	desc, match := map[string]string{}, map[string]string{}
	for _, s := range r.Search {
		ids = append(ids, s.ID)
		desc[s.ID], match[s.ID] = s.Description, s.Match.Text
	}
	if len(ids) == 0 {
		// Full-text search catches titles that are not a label prefix.
		q = url.Values{"action": {"query"}, "list": {"search"}, "srsearch": {title + " haswbstatement:" + tmdbProp[k]},
			"srlimit": {"8"}, "format": {"json"}}
		var fr struct {
			Query struct{ Search []struct{ Title string } }
		}
		if err := c.getJSON(ctx, wikidataAPI+"?"+q.Encode(), nil, &fr); err != nil {
			return nil, err
		}
		for _, s := range fr.Query.Search {
			ids = append(ids, s.Title)
		}
		if len(ids) == 0 {
			return nil, nil
		}
	}
	ents, err := c.entities(ctx, ids, "labels|descriptions|claims")
	if err != nil {
		return nil, err
	}
	var out []Candidate
	for _, id := range ids {
		e := ents[id]
		if e == nil || !e.is(k) {
			continue
		}
		cd := Candidate{ID: id, Title: e.label(), Description: desc[id], Year: e.year()}
		if cd.Description == "" {
			cd.Description = e.Descriptions["cs"].Value
		}
		for _, l := range e.Labels {
			cd.matched = append(cd.matched, l.Value)
		}
		if match[id] != "" {
			cd.matched = append(cd.matched, match[id])
		}
		out = append(out, cd)
	}
	return out, nil
}

// details loads a Wikidata entity with labels of its genres and people, and the Wikipedia summary.
func (c *client) details(ctx context.Context, k Kind, id string) (Details, error) {
	ents, err := c.entities(ctx, []string{id}, "labels|claims|sitelinks")
	if err != nil {
		return Details{}, err
	}
	e := ents[id]
	if e == nil || e.Labels == nil {
		return Details{}, errNotFound
	}
	d := Details{Wikidata: id, Title: e.label(), Year: e.year(), TMDb: e.str(tmdbProp[k])}
	for _, t := range values[struct{ Text string }](e, "P1476") {
		d.OrigTitle = t.Text
		break
	}
	for _, q := range values[struct{ Amount, Unit string }](e, "P2047") {
		if f, err := strconv.ParseFloat(strings.TrimPrefix(q.Amount, "+"), 64); err == nil {
			if strings.HasSuffix(q.Unit, "/Q25235") { // hours
				f *= 60
			}
			d.Runtime = int(f + 0.5)
		}
		break
	}
	genres, directors, cast := e.ids("P136"), e.ids("P57"), e.ids("P161")
	if len(cast) > 10 {
		cast = cast[:10]
	}
	if len(directors) > 1 {
		directors = directors[:1]
	}
	if people := append(append(append([]string{}, genres...), directors...), cast...); len(people) > 0 {
		if labels, err := c.entities(ctx, people, "labels"); err == nil {
			name := func(id string) string {
				if l := labels[id]; l != nil {
					return l.label()
				}
				return ""
			}
			for _, g := range genres {
				if n := name(g); n != "" && len(d.Genres) < 3 {
					d.Genres = append(d.Genres, n)
				}
			}
			for _, p := range directors {
				d.Director = name(p)
			}
			for _, p := range cast {
				if n := name(p); n != "" {
					d.Cast = append(d.Cast, n)
				}
			}
		}
	}
	// Czech article text; the English article more often has the poster as its image.
	for _, wiki := range []string{"cs", "en"} {
		title := e.Sitelinks[wiki+"wiki"].Title
		if title == "" {
			continue
		}
		s, err := c.summary(ctx, wiki, title)
		if err != nil {
			continue
		}
		if d.Overview == "" {
			d.Overview = s.Extract
		}
		if d.PosterURL == "" && s.Thumbnail.Height > s.Thumbnail.Width {
			d.PosterURL = s.Thumbnail.Source
		}
	}
	return d, nil
}

type summary struct {
	Extract   string
	Thumbnail struct {
		Source        string
		Width, Height int
	}
}

func (c *client) summary(ctx context.Context, wiki, title string) (summary, error) {
	var s summary
	u := "https://" + wiki + ".wikipedia.org/api/rest_v1/page/summary/" + url.PathEscape(strings.ReplaceAll(title, " ", "_"))
	err := c.getJSON(ctx, u, nil, &s)
	return s, err
}
