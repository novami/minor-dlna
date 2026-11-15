package library

import (
	"context"
	"database/sql"
	"io/fs"
	"log/slog"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/novami/minor-dlna/internal/config"
	"github.com/novami/minor-dlna/internal/dlna"
	"github.com/novami/minor-dlna/internal/media"
)

const (
	checkInterval = time.Minute     // cheap folder mtime check
	fullInterval  = 6 * time.Hour   // full rescan catches in-place edits
	settleTime    = 2 * time.Minute // files modified more recently may still be copying
)

// Scanner keeps the index in sync with the file system.
//
// Change detection avoids per-file watches (kqueue needs one descriptor per file):
// every minute it stats all known folders, and a changed folder mtime triggers a rescan of that library.
type Scanner struct {
	cat      *Catalog
	prober   *media.Prober
	OnChange func(updateID uint32)

	mu      sync.Mutex
	dirs    map[int64]map[string]time.Time // library → folder → mtime at last scan
	pending map[int64]bool                 // library has files still being written
}

func NewScanner(cat *Catalog, prober *media.Prober) *Scanner {
	return &Scanner{cat: cat, prober: prober, dirs: map[int64]map[string]time.Time{}, pending: map[int64]bool{}}
}

// Run scans everything, then keeps checking for changes until ctx is done.
func (s *Scanner) Run(ctx context.Context) {
	if !s.prober.Available() {
		slog.Info("ffprobe not found, media details (duration, codecs) disabled; install with: brew install ffmpeg")
	}
	s.scanAll(ctx, true)
	check := time.NewTicker(checkInterval)
	full := time.NewTicker(fullInterval)
	defer check.Stop()
	defer full.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-full.C:
			s.scanAll(ctx, true)
		case <-check.C:
			s.scanAll(ctx, false)
		}
	}
}

func (s *Scanner) scanAll(ctx context.Context, force bool) {
	changed := false
	for _, lib := range s.cat.Libraries() {
		if !force && !s.needsScan(lib) {
			continue
		}
		start := time.Now()
		st, err := s.ScanLibrary(ctx, lib)
		if err != nil {
			if ctx.Err() == nil {
				slog.Error("scan failed", "library", lib.Name, "err", err)
			}
			continue
		}
		if st.changed() {
			changed = true
			slog.Info("library scanned", "library", lib.Name, "added", st.added, "updated", st.updated, "removed", st.removed, "took", time.Since(start).Round(time.Millisecond))
		}
	}
	if s.probePending(ctx) {
		changed = true
	}
	if changed {
		s.bump(ctx)
	}
}

func (s *Scanner) bump(ctx context.Context) {
	id, err := s.cat.st.BumpUpdateID(ctx)
	if err != nil {
		slog.Error("update id", "err", err)
		return
	}
	if s.OnChange != nil {
		s.OnChange(id)
	}
}

// needsScan reports whether any known folder changed, a root appeared, or files were still being copied.
func (s *Scanner) needsScan(lib *Library) bool {
	s.mu.Lock()
	known, pending := s.dirs[lib.ID], s.pending[lib.ID]
	s.mu.Unlock()
	if pending {
		return true
	}
	for _, root := range lib.Paths {
		if _, ok := known[root]; !ok {
			if _, err := os.Stat(root); err == nil {
				return true // e.g. external drive mounted
			}
		}
	}
	for dir, mt := range known {
		fi, err := os.Stat(dir)
		if err != nil || !fi.ModTime().Equal(mt) {
			return true
		}
	}
	return false
}

type scanStats struct{ added, updated, removed int }

func (s scanStats) changed() bool { return s.added+s.updated+s.removed > 0 }

type found struct {
	root    int
	rel     string
	path    string
	format  dlna.Format
	size    int64
	mtime   int64
	relDir  string
	dirName string
}

// ScanLibrary walks the library folders and reconciles the index.
func (s *Scanner) ScanLibrary(ctx context.Context, lib *Library) (scanStats, error) {
	want := kindFor(lib.Type)
	dirMtimes := map[string]time.Time{}
	var files []found
	recent := false
	cutoff := time.Now().Add(-settleTime)

	for root, base := range lib.Paths {
		err := filepath.WalkDir(base, func(p string, d fs.DirEntry, err error) error {
			if ctx.Err() != nil {
				return ctx.Err()
			}
			if err != nil {
				if p == base {
					slog.Warn("library folder unavailable", "library", lib.Name, "path", base, "err", err)
				}
				return nil
			}
			if p != base && strings.HasPrefix(d.Name(), ".") {
				if d.IsDir() {
					return filepath.SkipDir
				}
				return nil
			}
			info, err := d.Info()
			if err != nil {
				return nil
			}
			if d.IsDir() {
				dirMtimes[p] = info.ModTime()
				return nil
			}
			f, ok := dlna.Lookup(d.Name())
			if !ok || f.Kind != want || !info.Mode().IsRegular() {
				return nil
			}
			if info.ModTime().After(cutoff) {
				recent = true
			}
			rel, _ := filepath.Rel(base, p)
			relDir := filepath.Dir(rel)
			if relDir == "." {
				relDir = ""
			}
			files = append(files, found{root: root, rel: rel, path: p, format: f, size: info.Size(), mtime: info.ModTime().Unix(), relDir: relDir})
			return nil
		})
		if err != nil {
			return scanStats{}, err
		}
	}

	st, err := s.reconcile(ctx, lib, files)
	if err != nil {
		return st, err
	}
	s.mu.Lock()
	s.dirs[lib.ID] = dirMtimes
	s.pending[lib.ID] = recent
	s.mu.Unlock()
	return st, nil
}

func (s *Scanner) reconcile(ctx context.Context, lib *Library, files []found) (scanStats, error) {
	var st scanStats
	tx, err := s.cat.st.DB.BeginTx(ctx, nil)
	if err != nil {
		return st, err
	}
	defer tx.Rollback()

	type existing struct {
		id          int64
		size, mtime int64
		seen        bool
	}
	items := map[string]*existing{}
	rows, err := tx.QueryContext(ctx, `SELECT id, path, size, mtime FROM item WHERE library_id = ?`, lib.ID)
	if err != nil {
		return st, err
	}
	for rows.Next() {
		var e existing
		var p string
		if err := rows.Scan(&e.id, &p, &e.size, &e.mtime); err != nil {
			rows.Close()
			return st, err
		}
		items[p] = &e
	}
	rows.Close()
	firstScan := len(items) == 0

	type dirKey struct {
		root int
		rel  string
	}
	dirs := map[dirKey]int64{}
	usedDirs := map[int64]bool{}
	rows, err = tx.QueryContext(ctx, `SELECT id, root, rel FROM dir WHERE library_id = ?`, lib.ID)
	if err != nil {
		return st, err
	}
	for rows.Next() {
		var id int64
		var root int
		var rel string
		if err := rows.Scan(&id, &root, &rel); err != nil {
			rows.Close()
			return st, err
		}
		dirs[dirKey{root, rel}] = id
	}
	rows.Close()

	var ensureDir func(root int, rel string) (int64, error)
	ensureDir = func(root int, rel string) (int64, error) {
		key := dirKey{root, rel}
		if id, ok := dirs[key]; ok {
			usedDirs[id] = true
			return id, nil
		}
		var parent sql.NullInt64
		name := filepath.Base(lib.Paths[root])
		if rel != "" {
			pr := filepath.Dir(rel)
			if pr == "." {
				pr = ""
			}
			pid, err := ensureDir(root, pr)
			if err != nil {
				return 0, err
			}
			parent = sql.NullInt64{Int64: pid, Valid: true}
			name = filepath.Base(rel)
		}
		var id int64
		err := tx.QueryRowContext(ctx, `INSERT INTO dir (library_id, root, rel, parent_id, name, sort_name) VALUES (?, ?, ?, ?, ?, ?) RETURNING id`,
			lib.ID, root, rel, parent, name, SortKey(name)).Scan(&id)
		if err != nil {
			return 0, err
		}
		dirs[key] = id
		usedDirs[id] = true
		return id, nil
	}

	shows := map[string]int64{}
	ensureShow := func(name string) (int64, error) {
		if id, ok := shows[name]; ok {
			return id, nil
		}
		var id int64
		err := tx.QueryRowContext(ctx, `INSERT INTO show (library_id, name, sort_name) VALUES (?, ?, ?)
			ON CONFLICT (library_id, name) DO UPDATE SET sort_name = excluded.sort_name RETURNING id`, lib.ID, name, SortKey(name)).Scan(&id)
		shows[name] = id
		return id, err
	}

	now := time.Now().Unix()
	for _, f := range files {
		dirID, err := ensureDir(f.root, f.relDir)
		if err != nil {
			return st, err
		}
		if e, ok := items[f.path]; ok {
			e.seen = true
			if e.size == f.size && e.mtime == f.mtime {
				continue
			}
			if _, err := tx.ExecContext(ctx, `UPDATE item SET size = ?, mtime = ?, dir_id = ?, probed = 0 WHERE id = ?`, f.size, f.mtime, dirID, e.id); err != nil {
				return st, err
			}
			st.updated++
			continue
		}
		m := describe(lib.Type, f.rel)
		var showID sql.NullInt64
		if m.show != "" {
			id, err := ensureShow(m.show)
			if err != nil {
				return st, err
			}
			showID = sql.NullInt64{Int64: id, Valid: true}
		}
		// On the very first import use file time, so "recently added" reflects real history.
		added := now
		if firstScan {
			added = f.mtime
		}
		_, err = tx.ExecContext(ctx, `INSERT INTO item (library_id, dir_id, path, name, kind, mime, size, mtime, added_at,
			title, sort_title, year, show_id, season, episode, episode_title)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			lib.ID, dirID, f.path, filepath.Base(f.path), int(f.format.Kind), f.format.Mime, f.size, f.mtime, added,
			m.title, SortKey(m.sortTitle), nullInt(m.year), showID, nullIntIf(m.show != "", m.season), nullIntIf(m.show != "", m.episode), nullStr(m.epTitle))
		if err != nil {
			return st, err
		}
		st.added++
	}

	for _, e := range items {
		if !e.seen {
			if _, err := tx.ExecContext(ctx, `DELETE FROM item WHERE id = ?`, e.id); err != nil {
				return st, err
			}
			st.removed++
		}
	}
	for _, id := range dirs {
		if !usedDirs[id] {
			if _, err := tx.ExecContext(ctx, `DELETE FROM dir WHERE id = ?`, id); err != nil {
				return st, err
			}
		}
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM show WHERE library_id = ? AND id NOT IN (SELECT show_id FROM item WHERE show_id IS NOT NULL)`, lib.ID); err != nil {
		return st, err
	}
	return st, tx.Commit()
}

type described struct {
	title, sortTitle string
	year             int
	show             string
	season, episode  int
	epTitle          string
}

func describe(lt config.LibraryType, rel string) described {
	name := filepath.Base(rel)
	switch lt {
	case config.Movies:
		t, y := ParseMovie(name)
		return described{title: t, sortTitle: t, year: y}
	case config.Shows:
		if ep, ok := ParseEpisode(rel); ok {
			return described{
				title: ep.Show, sortTitle: ep.Show + " " + itoa(ep.Season) + " " + itoa(ep.Episode),
				show: ep.Show, season: ep.Season, episode: ep.Episode, epTitle: ep.Title,
			}
		}
	}
	t := stripExt(name)
	return described{title: t, sortTitle: t}
}

// probePending fills technical details for new or changed items. Reports whether anything was updated.
func (s *Scanner) probePending(ctx context.Context) bool {
	if !s.prober.Available() {
		return false
	}
	updated := false
	for ctx.Err() == nil {
		rows, err := s.cat.st.DB.QueryContext(ctx, `SELECT id, path FROM item WHERE probed = 0 AND kind IN (?, ?) LIMIT 64`, int(dlna.Video), int(dlna.Audio))
		if err != nil {
			slog.Error("probe query", "err", err)
			return updated
		}
		type job struct {
			id   int64
			path string
		}
		var jobs []job
		for rows.Next() {
			var j job
			if rows.Scan(&j.id, &j.path) == nil {
				jobs = append(jobs, j)
			}
		}
		rows.Close()
		if len(jobs) == 0 {
			return updated
		}
		var wg sync.WaitGroup
		sem := make(chan struct{}, 2)
		for _, j := range jobs {
			wg.Add(1)
			sem <- struct{}{}
			go func() {
				defer wg.Done()
				defer func() { <-sem }()
				info, err := s.prober.Probe(ctx, j.path)
				if ctx.Err() != nil {
					return
				}
				state := 1
				if err != nil {
					state = 2 // failed, don't retry until the file changes
					slog.Debug("probe failed", "path", j.path, "err", err)
				}
				_, err = s.cat.st.DB.ExecContext(ctx, `UPDATE item SET probed = ?, duration_ms = ?, bitrate = ?, container = ?,
					video_codec = ?, audio_codec = ?, width = ?, height = ? WHERE id = ?`,
					state, nullInt64(info.DurationMs), nullInt64(info.Bitrate), nullStr(info.Container),
					nullStr(info.VideoCodec), nullStr(info.AudioCodec), nullInt(info.Width), nullInt(info.Height), j.id)
				if err != nil {
					slog.Error("probe update", "err", err)
				}
			}()
		}
		wg.Wait()
		updated = true
	}
	return updated
}

func itoa(n int) string { return strconv.Itoa(n) }

func kindFor(lt config.LibraryType) dlna.Kind {
	switch lt {
	case config.Photos:
		return dlna.Image
	case config.Music:
		return dlna.Audio
	default:
		return dlna.Video
	}
}

func nullInt(n int) sql.NullInt64 { return sql.NullInt64{Int64: int64(n), Valid: n != 0} }

func nullInt64(n int64) sql.NullInt64 { return sql.NullInt64{Int64: n, Valid: n != 0} }

func nullIntIf(ok bool, n int) sql.NullInt64 { return sql.NullInt64{Int64: int64(n), Valid: ok} }

func nullStr(s string) sql.NullString { return sql.NullString{String: s, Valid: s != ""} }
