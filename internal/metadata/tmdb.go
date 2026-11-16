package metadata

import (
	"context"
	"net/http"
	"net/url"
	"strconv"
)

const (
	tmdbAPI    = "https://api.themoviedb.org/3"
	tmdbImages = "https://image.tmdb.org/t/p/w342"
)

type tmdbResult struct {
	ID            int
	Title, Name   string
	OriginalTitle string `json:"original_title"`
	OriginalName  string `json:"original_name"`
	Overview      string
	PosterPath    string  `json:"poster_path"`
	VoteAverage   float64 `json:"vote_average"`
	Runtime       int
	ReleaseDate   string `json:"release_date"`
	FirstAirDate  string `json:"first_air_date"`
	Genres        []struct{ Name string }
}

func tmdbPath(k Kind) string {
	if k == Show {
		return "/tv"
	}
	return "/movie"
}

func (c *client) tmdb(ctx context.Context, token, path string, q url.Values, v any) error {
	q.Set("language", "cs-CZ")
	return c.getJSON(ctx, tmdbAPI+path+"?"+q.Encode(), http.Header{"Authorization": {"Bearer " + token}}, v)
}

// tmdbSearch is the fallback when Wikidata knows nothing: the best TMDb hit's ID.
func (c *client) tmdbSearch(ctx context.Context, token string, k Kind, title string, year int) (string, error) {
	q := url.Values{"query": {title}}
	if year > 0 {
		if k == Show {
			q.Set("first_air_date_year", strconv.Itoa(year))
		} else {
			q.Set("year", strconv.Itoa(year))
		}
	}
	var r struct{ Results []tmdbResult }
	if err := c.tmdb(ctx, token, "/search"+tmdbPath(k), q, &r); err != nil {
		return "", err
	}
	for _, res := range r.Results {
		t := res.Title + res.Name
		if similarity(title, []string{t, res.OriginalTitle + res.OriginalName}) >= exact {
			return strconv.Itoa(res.ID), nil
		}
	}
	return "", nil
}

// fillTMDb adds the poster, Czech overview, rating and anything Wikidata lacked.
func (c *client) fillTMDb(ctx context.Context, token string, k Kind, d *Details) error {
	var r tmdbResult
	if err := c.tmdb(ctx, token, tmdbPath(k)+"/"+url.PathEscape(d.TMDb), url.Values{}, &r); err != nil {
		return err
	}
	if r.PosterPath != "" {
		d.PosterURL = tmdbImages + r.PosterPath
	}
	if r.Overview != "" {
		d.Overview = r.Overview
	}
	d.Rating = r.VoteAverage
	if d.Title == "" {
		d.Title = r.Title + r.Name
	}
	if d.OrigTitle == "" {
		d.OrigTitle = r.OriginalTitle + r.OriginalName
	}
	if d.Runtime == 0 {
		d.Runtime = r.Runtime
	}
	if d.Year == 0 {
		date := r.ReleaseDate + r.FirstAirDate
		if len(date) >= 4 {
			d.Year, _ = strconv.Atoi(date[:4])
		}
	}
	if len(d.Genres) == 0 {
		for _, g := range r.Genres {
			d.Genres = append(d.Genres, g.Name)
		}
	}
	return nil
}
