// Package metadata matches movies and shows to Wikidata (and optionally TMDb) and caches their posters.
package metadata

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
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

	"github.com/novami/minor-dlna/internal/config"
	"github.com/novami/minor-dlna/internal/dlna"
	"github.com/novami/minor-dlna/internal/library"
	"github.com/novami/minor-dlna/internal/store"
	"github.com/novami/minor-dlna/internal/thumbs"
)

const (
	StatusUnmatched = 0
	StatusAuto      = 1
	StatusManual    = 2
	StatusNone      = 3

	refreshAfter = 30 * 24 * time.Hour
	retryAfter   = 7 * 24 * time.Hour
	passInterval = 6 * time.Hour
	pause        = 300 * time.Millisecond // between lookups, to be gentle to the free APIs
)

var errNotFound = errors.New("not found")

type Service struct {
	st      *store.Store
	dir     string
	c       client
	token   string
	enabled bool
	// OnChange is called after metadata changed, so TVs reload the listing.
	OnChange func()

	kick chan struct{}
	mu   sync.Mutex // one lookup at a time (background pass vs. manual match)
}

func New(st *store.Store, dir string, cfg config.Metadata) *Service {
	return &Service{st: st, dir: dir, c: client{http: &http.Client{Timeout: 20 * time.Second}},
		token: strings.TrimSpace(cfg.TMDbToken), enabled: cfg.On(), kick: make(chan struct{}, 1)}
}

func (s *Service) Enabled() bool { return s.enabled }
func (s *Service) HasTMDb() bool { return s.token != "" }

// Kick requests a pass, e.g. after a library scan.
func (s *Service) Kick() {
	select {
	case s.kick <- struct{}{}:
	default:
	}
}

// Run looks up new titles after each kick and refreshes old ones periodically.
func (s *Service) Run(ctx context.Context) {
	if !s.enabled {
		return
	}
	t := time.NewTicker(passInterval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-s.kick:
		case <-t.C:
		}
		if err := s.pass(ctx); err != nil && ctx.Err() == nil {
			slog.Warn("metadata lookup stopped", "err", err)
		}
	}
}

type row struct {
	id       int64
	kind     Kind
	query    string
	status   int
	wikidata string
}

func splitQuery(q string) (title string, year int) {
	i := strings.LastIndexByte(q, '|')
	if i < 0 {
		return q, 0
	}
	year, _ = strconv.Atoi(q[i+1:])
	return q[:i], year
}

func (s *Service) pass(ctx context.Context) error {
	if err := s.sync(ctx); err != nil {
		return err
	}
	now := time.Now()
	rows, err := s.st.DB.QueryContext(ctx, `SELECT id, kind, query, status, IFNULL(wikidata, '') FROM meta_match
		WHERE (status = ? AND checked_at < ?) OR (status IN (?, ?) AND checked_at < ?) ORDER BY checked_at, id`,
		StatusUnmatched, now.Add(-retryAfter).Unix(), StatusAuto, StatusManual, now.Add(-refreshAfter).Unix())
	if err != nil {
		return err
	}
	var due []row
	for rows.Next() {
		var r row
		if err := rows.Scan(&r.id, &r.kind, &r.query, &r.status, &r.wikidata); err != nil {
			rows.Close()
			return err
		}
		due = append(due, r)
	}
	rows.Close()
	if len(due) > 0 {
		slog.Info("looking up movie metadata", "titles", len(due))
	}
	changed := 0
	defer func() {
		if changed > 0 && s.OnChange != nil {
			s.OnChange()
		}
	}()
	for _, r := range due {
		if err := s.lookup(ctx, r); err != nil {
			return err
		}
		changed++
		if changed%20 == 0 && s.OnChange != nil {
			s.OnChange()
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(pause):
		}
	}
	return nil
}

// sync adds a row for every movie title and show in the libraries and drops automatic rows nothing uses.
func (s *Service) sync(ctx context.Context) error {
	movieKey := `i.title || '|' || IFNULL(i.year, '')`
	_, err := s.st.DB.ExecContext(ctx, `INSERT OR IGNORE INTO meta_match (kind, query)
		SELECT DISTINCT 'movies', `+movieKey+` FROM item i JOIN library l ON l.id = i.library_id
		WHERE l.type = 'movies' AND i.kind = ?;
		INSERT OR IGNORE INTO meta_match (kind, query)
		SELECT 'shows', s.name || '|' FROM show s JOIN library l ON l.id = s.library_id WHERE l.type = 'shows'`, int(dlna.Video))
	if err != nil {
		return err
	}
	stale := `status IN (0, 1) AND NOT (
		(kind = 'movies' AND EXISTS (SELECT 1 FROM item i JOIN library l ON l.id = i.library_id
			WHERE l.type = 'movies' AND ` + movieKey + ` = meta_match.query))
		OR (kind = 'shows' AND EXISTS (SELECT 1 FROM show s JOIN library l ON l.id = s.library_id
			WHERE l.type = 'shows' AND s.name || '|' = meta_match.query)))`
	rows, err := s.st.DB.QueryContext(ctx, `SELECT id FROM meta_match WHERE poster = 1 AND `+stale)
	if err != nil {
		return err
	}
	var ids []int64
	for rows.Next() {
		var id int64
		if rows.Scan(&id) == nil {
			ids = append(ids, id)
		}
	}
	rows.Close()
	if _, err := s.st.DB.ExecContext(ctx, `DELETE FROM meta_match WHERE `+stale); err != nil {
		return err
	}
	for _, id := range ids {
		s.removePoster(id)
	}
	return nil
}

// lookup matches one row automatically, or refreshes a hand-picked match. Only network failures are returned.
func (s *Service) lookup(ctx context.Context, r row) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	title, year := splitQuery(r.query)
	var d Details
	var err error
	switch {
	case r.status == StatusManual && r.wikidata != "":
		d, err = s.c.details(ctx, r.kind, r.wikidata)
	case r.status == StatusManual: // TMDb-only manual match: keep it
		return s.touch(ctx, r.id)
	default:
		d, err = s.match(ctx, r.kind, title, year)
	}
	if errors.Is(err, errNotFound) {
		return s.touch(ctx, r.id)
	}
	if err != nil {
		return err
	}
	status := r.status
	if status != StatusManual {
		status = StatusAuto
	}
	return s.save(ctx, r.id, status, d)
}

// match finds the movie or show a file name refers to; errNotFound when unsure.
func (s *Service) match(ctx context.Context, k Kind, title string, year int) (Details, error) {
	for _, q := range searchTitles(title) {
		cands, err := s.c.search(ctx, k, q)
		if err != nil {
			return Details{}, err
		}
		if best, ok := choose(q, year, cands); ok {
			return s.c.details(ctx, k, best.ID)
		}
	}
	if s.token != "" {
		id, err := s.c.tmdbSearch(ctx, s.token, k, title, year)
		if err != nil {
			slog.Warn("tmdb search", "err", err)
		} else if id != "" {
			return Details{TMDb: id}, nil
		}
	}
	return Details{}, errNotFound
}

// searchTitles is the parsed title, and without a trailing " - extra words" that release names often carry.
func searchTitles(title string) []string {
	out := []string{title}
	if i := strings.Index(title, " - "); i > 0 {
		out = append(out, title[:i])
	}
	return out
}

func (s *Service) touch(ctx context.Context, id int64) error {
	_, err := s.st.DB.ExecContext(ctx, `UPDATE meta_match SET checked_at = ? WHERE id = ?`, time.Now().Unix(), id)
	return err
}

func (s *Service) save(ctx context.Context, id int64, status int, d Details) error {
	if s.token != "" && d.TMDb != "" {
		if err := s.c.fillTMDb(ctx, s.token, kindOf(ctx, s, id), &d); err != nil {
			slog.Warn("tmdb details", "id", d.TMDb, "err", err)
		}
	}
	poster := 0
	if d.PosterURL != "" {
		if err := s.fetchPoster(ctx, id, d.PosterURL); err != nil {
			slog.Warn("poster download", "url", d.PosterURL, "err", err)
		} else {
			poster = 1
		}
	}
	if poster == 0 {
		s.removePoster(id)
	}
	_, err := s.st.DB.ExecContext(ctx, `UPDATE meta_match SET status = ?, wikidata = ?, tmdb = ?, title = ?, sort_title = ?,
		orig_title = ?, year = ?, overview = ?, genres = ?, director = ?, cast = ?, runtime = ?, rating = ?, poster = ?, checked_at = ?
		WHERE id = ?`,
		status, nullStr(d.Wikidata), nullStr(d.TMDb), nullStr(d.Title), nullStr(library.SortKey(d.Title)),
		nullStr(d.OrigTitle), nullInt(d.Year), nullStr(d.Overview), nullStr(strings.Join(d.Genres, ", ")),
		nullStr(d.Director), nullStr(strings.Join(d.Cast, ", ")), nullInt(d.Runtime), nullFloat(d.Rating), poster, time.Now().Unix(), id)
	return err
}

func kindOf(ctx context.Context, s *Service, id int64) Kind {
	var k Kind
	_ = s.st.DB.QueryRowContext(ctx, `SELECT kind FROM meta_match WHERE id = ?`, id).Scan(&k)
	return k
}

// Entry is one matched (or unmatched) title for the settings page.
type Entry struct {
	ID        int64  `json:"id"`
	Kind      Kind   `json:"kind"`
	FileTitle string `json:"file_title"`
	FileYear  int    `json:"file_year,omitempty"`
	Status    int    `json:"status"`
	Title     string `json:"title,omitempty"`
	Year      int    `json:"year,omitempty"`
	Wikidata  string `json:"wikidata,omitempty"`
	Poster    string `json:"poster,omitempty"`
	Checked   bool   `json:"checked"`
}

// Entries lists all titles, unmatched first.
func (s *Service) Entries(ctx context.Context) ([]Entry, error) {
	rows, err := s.st.DB.QueryContext(ctx, `SELECT id, kind, query, status, IFNULL(title, ''), IFNULL(year, 0), IFNULL(wikidata, ''), poster, checked_at
		FROM meta_match ORDER BY status = 0 AND checked_at > 0 DESC, kind, IFNULL(sort_title, query)`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Entry{}
	for rows.Next() {
		var e Entry
		var q string
		var poster bool
		var checked int64
		if err := rows.Scan(&e.ID, &e.Kind, &q, &e.Status, &e.Title, &e.Year, &e.Wikidata, &poster, &checked); err != nil {
			return nil, err
		}
		e.FileTitle, e.FileYear = splitQuery(q)
		e.Checked = checked > 0
		if poster {
			e.Poster = PosterPath(e.ID, "sm")
		}
		out = append(out, e)
	}
	return out, rows.Err()
}

// Search lists Wikidata candidates for a manual match.
func (s *Service) Search(ctx context.Context, id int64, q string) ([]Candidate, error) {
	k := kindOf(ctx, s, id)
	if k == "" {
		return nil, errNotFound
	}
	c, err := s.c.search(ctx, k, q)
	if c == nil {
		c = []Candidate{}
	}
	return c, err
}

// Set matches a title by hand to a Wikidata entity, or to nothing when qid is empty.
func (s *Service) Set(ctx context.Context, id int64, qid string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	k := kindOf(ctx, s, id)
	if k == "" {
		return errNotFound
	}
	var d Details
	status := StatusNone
	if qid != "" {
		var err error
		if d, err = s.c.details(ctx, k, qid); err != nil {
			return err
		}
		status = StatusManual
	}
	if err := s.save(ctx, id, status, d); err != nil {
		return err
	}
	if s.OnChange != nil {
		s.OnChange()
	}
	return nil
}

// Rematch forgets a match so the next pass looks the title up again.
func (s *Service) Rematch(ctx context.Context, id int64) error {
	if _, err := s.st.DB.ExecContext(ctx, `UPDATE meta_match SET status = 0, checked_at = 0 WHERE id = ?`, id); err != nil {
		return err
	}
	s.Kick()
	return nil
}

// ---------- posters ----------

// PosterPath is the URL path of a cached poster: size tn (DLNA) or sm (web).
func PosterPath(id int64, size string) string {
	return "/poster/" + strconv.FormatInt(id, 10) + "/" + size + ".jpg"
}

func (s *Service) posterFile(id int64, size string) string {
	return filepath.Join(s.dir, strconv.FormatInt(id, 10)+"-"+size+".jpg")
}

func (s *Service) removePoster(id int64) {
	for _, size := range []string{"tn", "sm"} {
		_ = os.Remove(s.posterFile(id, size))
	}
}

func (s *Service) fetchPoster(ctx context.Context, id int64, u string) error {
	if err := os.MkdirAll(s.dir, 0o755); err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return err
	}
	req.Header.Set("User-Agent", userAgent)
	resp, err := s.c.http.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	src := filepath.Join(s.dir, strconv.FormatInt(id, 10)+".download")
	defer os.Remove(src)
	f, err := os.Create(src)
	if err != nil {
		return err
	}
	_, err = io.Copy(f, io.LimitReader(resp.Body, 10<<20))
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		return err
	}
	for size, px := range map[string]string{"sm": "640", "tn": "160"} {
		out, err := exec.CommandContext(ctx, "/usr/bin/sips", "-s", "format", "jpeg", "-s", "formatOptions", "85",
			"-Z", px, src, "--out", s.posterFile(id, size)).CombinedOutput()
		if err != nil {
			return fmt.Errorf("sips: %v: %s", err, strings.TrimSpace(string(out)))
		}
	}
	return nil
}

// ServeHTTP serves /poster/<id>/<tn|sm>.jpg.
func (s *Service) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	parts := strings.Split(strings.TrimPrefix(r.URL.Path, "/poster/"), "/")
	if len(parts) != 2 || (parts[1] != "tn.jpg" && parts[1] != "sm.jpg") {
		http.NotFound(w, r)
		return
	}
	id, err := strconv.ParseInt(parts[0], 10, 64)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	name := strings.TrimSuffix(parts[1], ".jpg")
	f, err := os.Open(s.posterFile(id, name))
	if err != nil {
		http.NotFound(w, r)
		return
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Content-Type", "image/jpeg")
	if r.Header.Get("getcontentFeatures.dlna.org") == "1" {
		size, _ := thumbs.Lookup(name)
		w.Header().Set("contentFeatures.dlna.org", thumbs.ContentFeatures(size))
	}
	http.ServeContent(w, r, "", fi.ModTime(), f)
}

func nullStr(s string) sql.NullString { return sql.NullString{String: s, Valid: s != ""} }
func nullInt(n int) sql.NullInt64     { return sql.NullInt64{Int64: int64(n), Valid: n > 0} }
func nullFloat(f float64) sql.NullFloat64 {
	return sql.NullFloat64{Float64: f, Valid: f > 0}
}
