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
	OnRemove func(itemIDs []int64) // e.g. purge cached thumbnails

	rescan chan struct{}

	mu       sync.Mutex
	scanning bool
	dirs     map[int64]map[string]time.Time // library → folder → mtime at last scan
	pending  map[int64]bool                 // library has files still being written
}

func NewScanner(cat *Catalog, prober *media.Prober) *Scanner {
	return &Scanner{cat: cat, prober: prober, rescan: make(chan struct{}, 1), dirs: map[int64]map[string]time.Time{}, pending: map[int64]bool{}}
}

// Rescan requests a full scan of all libraries.
func (s *Scanner) Rescan() {
	select {
	case s.rescan <- struct{}{}:
	default:
	}
}

// Scanning reports whether a scan is in progress.
func (s *Scanner) Scanning() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.scanning
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
		case <-s.rescan:
			s.scanAll(ctx, true)
		case <-check.C:
			s.scanAll(ctx, false)
		}
	}
}

func (s *Scanner) scanAll(ctx context.Context, force bool) {
	s.mu.Lock()
	s.scanning = true
	s.mu.Unlock()
	defer func() {
		s.mu.Lock()
		s.scanning = false
		s.mu.Unlock()
	}()
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
	root   int
	rel    string
	path   string
	format dlna.Format
	size   int64
	mtime  int64
	relDir string
	meta   described
	sub    string // external subtitle path
}

type existing struct {
	id          int64
	size, mtime int64
	sub         string
	seen        bool
}

// ScanLibrary walks the library folders and reconciles the index.
func (s *Scanner) ScanLibrary(ctx context.Context, lib *Library) (scanStats, error) {
	known, err := s.existingItems(ctx, lib.ID)
	if err != nil {
		return scanStats{}, err
	}
	want := kindFor(lib.Type)
	dirMtimes := map[string]time.Time{}
	var files []found
	subs := map[string][]string{} // folder → .srt file names
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
			if want == dlna.Video && strings.EqualFold(filepath.Ext(d.Name()), ".srt") {
				subs[filepath.Dir(p)] = append(subs[filepath.Dir(p)], d.Name())
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
			fd := found{root: root, rel: rel, path: p, format: f, size: info.Size(), mtime: info.ModTime().Unix(), relDir: relDir}
			// Read file metadata only for new or changed files, outside the write transaction.
			if e, ok := known[p]; !ok || e.size != fd.size || e.mtime != fd.mtime {
				fd.meta = describe(ctx, lib.Type, p, rel, info.ModTime())
			}
			files = append(files, fd)
			return nil
		})
		if err != nil {
			return scanStats{}, err
		}
	}

	for i := range files {
		files[i].sub = matchSubtitle(files[i].path, subs[filepath.Dir(files[i].path)])
	}
	st, removed, err := s.reconcile(ctx, lib, files)
	if err != nil {
		return st, err
	}
	if len(removed) > 0 && s.OnRemove != nil {
		s.OnRemove(removed)
	}
	s.mu.Lock()
	s.dirs[lib.ID] = dirMtimes
	s.pending[lib.ID] = recent
	s.mu.Unlock()
	return st, nil
}

func (s *Scanner) existingItems(ctx context.Context, libID int64) (map[string]*existing, error) {
	return loadExisting(ctx, s.cat.st.DB, libID)
}

type querier interface {
	QueryContext(ctx context.Context, q string, args ...any) (*sql.Rows, error)
}

func loadExisting(ctx context.Context, db querier, libID int64) (map[string]*existing, error) {
	rows, err := db.QueryContext(ctx, `SELECT id, path, size, mtime, COALESCE(subtitle, '') FROM item WHERE library_id = ?`, libID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := map[string]*existing{}
	for rows.Next() {
		var e existing
		var p string
		if err := rows.Scan(&e.id, &p, &e.size, &e.mtime, &e.sub); err != nil {
			return nil, err
		}
		items[p] = &e
	}
	return items, rows.Err()
}

// matchSubtitle picks "<video>.srt" or "<video>.<lang>.srt", preferring Czech.
func matchSubtitle(videoPath string, srts []string) string {
	base := strings.ToLower(strings.TrimSuffix(filepath.Base(videoPath), filepath.Ext(videoPath)))
	best, bestScore := "", 99
	for _, name := range srts {
		stem := strings.ToLower(strings.TrimSuffix(name, filepath.Ext(name)))
		score := -1
		switch {
		case stem == base:
			score = 1
		case strings.HasPrefix(stem, base+"."):
			score = 2
			switch strings.TrimPrefix(stem, base+".") {
			case "cs", "cz", "cze", "ces", "czech", "cesky", "česky":
				score = 0
			}
		}
		if score >= 0 && score < bestScore {
			best, bestScore = name, score
		}
	}
	if best == "" {
		return ""
	}
	return filepath.Join(filepath.Dir(videoPath), best)
}

func (s *Scanner) reconcile(ctx context.Context, lib *Library, files []found) (scanStats, []int64, error) {
	var st scanStats
	tx, err := s.cat.st.DB.BeginTx(ctx, nil)
	if err != nil {
		return st, nil, err
	}
	defer tx.Rollback()

	items, err := loadExisting(ctx, tx, lib.ID)
	if err != nil {
		return st, nil, err
	}
	firstScan := len(items) == 0

	type dirKey struct {
		root int
		rel  string
	}
	dirs := map[dirKey]int64{}
	usedDirs := map[int64]bool{}
	rows, err := tx.QueryContext(ctx, `SELECT id, root, rel FROM dir WHERE library_id = ?`, lib.ID)
	if err != nil {
		return st, nil, err
	}
	for rows.Next() {
		var id int64
		var root int
		var rel string
		if err := rows.Scan(&id, &root, &rel); err != nil {
			rows.Close()
			return st, nil, err
		}
		dirs[dirKey{root, rel}] = id
	}
	rows.Close()

	var ensureDir func(root int, rel string) (int64, error)
	ensureDir = func(root int, rel string) (int64, error) {
		key := dirKey{root, rel}
		if id, ok := dirs[key]; ok {
			if !usedDirs[id] {
				usedDirs[id] = true
				// Ancestors must stay too: deleting an unused parent cascades to this folder and its items.
				if rel != "" {
					pr := filepath.Dir(rel)
					if pr == "." {
						pr = ""
					}
					if _, err := ensureDir(root, pr); err != nil {
						return 0, err
					}
				}
			}
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

	ents := newEntities(ctx, tx, lib.ID)
	now := time.Now().Unix()
	for _, f := range files {
		dirID, err := ensureDir(f.root, f.relDir)
		if err != nil {
			return st, nil, err
		}
		e, ok := items[f.path]
		if ok {
			e.seen = true
			if e.size == f.size && e.mtime == f.mtime {
				// Subtitles can appear or disappear without the video changing.
				if e.sub != f.sub {
					if _, err := tx.ExecContext(ctx, `UPDATE item SET subtitle = ? WHERE id = ?`, nullStr(f.sub), e.id); err != nil {
						return st, nil, err
					}
					st.updated++
				}
				continue
			}
		}
		ref, err := ents.resolve(f.meta)
		if err != nil {
			return st, nil, err
		}
		m := f.meta
		cols := []any{dirID, f.size, f.mtime, m.title, SortKey(m.sortTitle), nullInt(m.year), ref.show,
			nullIntIf(m.show != "", m.season), nullIntIf(m.show != "", m.episode), nullStr(m.epTitle),
			nullTime(m.taken), nullInt(m.width), nullInt(m.height), nullInt(m.orientation),
			nullStr(m.artist), ref.artist, ref.album, ref.genre, nullInt(m.disc), nullInt(m.track), m.hasArt, nullStr(f.sub)}
		if ok {
			_, err = tx.ExecContext(ctx, `UPDATE item SET dir_id = ?, size = ?, mtime = ?, title = ?, sort_title = ?, year = ?,
				show_id = ?, season = ?, episode = ?, episode_title = ?, taken_at = ?, width = ?, height = ?, orientation = ?,
				artist = ?, artist_id = ?, album_id = ?, genre_id = ?, disc = ?, track = ?, has_art = ?, subtitle = ?, probed = 0 WHERE id = ?`,
				append(cols, e.id)...)
			st.updated++
		} else {
			// On the very first import use file time, so "recently added" reflects real history.
			added := now
			if firstScan {
				added = f.mtime
			}
			_, err = tx.ExecContext(ctx, `INSERT INTO item (dir_id, size, mtime, title, sort_title, year,
				show_id, season, episode, episode_title, taken_at, width, height, orientation,
				artist, artist_id, album_id, genre_id, disc, track, has_art, subtitle, library_id, path, name, kind, mime, added_at)
				VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
				append(cols, lib.ID, f.path, filepath.Base(f.path), int(f.format.Kind), f.format.Mime, added)...)
			st.added++
		}
		if err != nil {
			return st, nil, err
		}
	}

	var removed []int64
	for _, e := range items {
		if !e.seen {
			if _, err := tx.ExecContext(ctx, `DELETE FROM item WHERE id = ?`, e.id); err != nil {
				return st, nil, err
			}
			removed = append(removed, e.id)
			st.removed++
		}
	}
	for _, id := range dirs {
		if !usedDirs[id] {
			if _, err := tx.ExecContext(ctx, `DELETE FROM dir WHERE id = ?`, id); err != nil {
				return st, nil, err
			}
		}
	}
	for _, q := range []string{
		`DELETE FROM show WHERE library_id = ? AND id NOT IN (SELECT show_id FROM item WHERE show_id IS NOT NULL)`,
		`DELETE FROM album WHERE library_id = ? AND id NOT IN (SELECT album_id FROM item WHERE album_id IS NOT NULL)`,
		`DELETE FROM artist WHERE library_id = ? AND id NOT IN (SELECT artist_id FROM item WHERE artist_id IS NOT NULL)`,
		`DELETE FROM genre WHERE library_id = ? AND id NOT IN (SELECT genre_id FROM item WHERE genre_id IS NOT NULL)`,
	} {
		if _, err := tx.ExecContext(ctx, q, lib.ID); err != nil {
			return st, nil, err
		}
	}
	return st, removed, tx.Commit()
}

// entities creates shows, artists, albums and genres on demand within a scan transaction.
type entities struct {
	ctx   context.Context
	tx    *sql.Tx
	libID int64
	cache map[string]int64
}

type entityRefs struct{ show, artist, album, genre sql.NullInt64 }

func newEntities(ctx context.Context, tx *sql.Tx, libID int64) *entities {
	return &entities{ctx: ctx, tx: tx, libID: libID, cache: map[string]int64{}}
}

func (e *entities) get(key, q string, args ...any) (sql.NullInt64, error) {
	if id, ok := e.cache[key]; ok {
		return sql.NullInt64{Int64: id, Valid: true}, nil
	}
	var id int64
	if err := e.tx.QueryRowContext(e.ctx, q, args...).Scan(&id); err != nil {
		return sql.NullInt64{}, err
	}
	e.cache[key] = id
	return sql.NullInt64{Int64: id, Valid: true}, nil
}

func (e *entities) resolve(m described) (entityRefs, error) {
	var r entityRefs
	var err error
	if m.show != "" {
		if r.show, err = e.get("s\x00"+m.show, `INSERT INTO show (library_id, name, sort_name) VALUES (?, ?, ?)
			ON CONFLICT (library_id, name) DO UPDATE SET sort_name = excluded.sort_name RETURNING id`, e.libID, m.show, SortKey(m.show)); err != nil {
			return r, err
		}
	}
	if m.albumArtist != "" {
		if r.artist, err = e.get("a\x00"+m.albumArtist, `INSERT INTO artist (library_id, name, sort_name) VALUES (?, ?, ?)
			ON CONFLICT (library_id, name) DO UPDATE SET sort_name = excluded.sort_name RETURNING id`, e.libID, m.albumArtist, SortKey(m.albumArtist)); err != nil {
			return r, err
		}
	}
	if m.album != "" {
		key := "b\x00" + strconv.FormatInt(r.artist.Int64, 10) + "\x00" + m.album
		if r.album, err = e.get(key, `INSERT INTO album (library_id, artist_id, title, sort_title, year) VALUES (?, ?, ?, ?, ?)
			ON CONFLICT (library_id, artist_id, title) DO UPDATE SET year = COALESCE(excluded.year, album.year) RETURNING id`,
			e.libID, r.artist, m.album, SortKey(m.album), nullInt(m.year)); err != nil {
			return r, err
		}
	}
	if m.genre != "" {
		if r.genre, err = e.get("g\x00"+m.genre, `INSERT INTO genre (library_id, name, sort_name) VALUES (?, ?, ?)
			ON CONFLICT (library_id, name) DO UPDATE SET sort_name = excluded.sort_name RETURNING id`, e.libID, m.genre, SortKey(m.genre)); err != nil {
			return r, err
		}
	}
	return r, nil
}

type described struct {
	title, sortTitle string
	year             int
	show             string
	season, episode  int
	epTitle          string
	// photos
	taken                      time.Time
	width, height, orientation int
	// music
	artist, albumArtist, album, genre string
	disc, track                       int
	hasArt                            bool
}

func describe(ctx context.Context, lt config.LibraryType, path, rel string, mtime time.Time) described {
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
	case config.Photos:
		t := stripExt(name)
		d := described{title: t, sortTitle: t, taken: mtime, hasArt: true}
		if pm, err := media.ReadPhoto(ctx, path); err == nil {
			d.width, d.height, d.orientation = pm.Width, pm.Height, pm.Orientation
			if !pm.Taken.IsZero() {
				d.taken = pm.Taken
			}
		} else {
			slog.Debug("photo metadata", "path", path, "err", err)
		}
		return d
	case config.Music:
		am := media.ReadAudio(path, rel)
		if am.Album != "" && am.AlbumArtist == "" {
			// Album rows are unique per artist; NULL would never conflict and duplicate albums.
			am.AlbumArtist = "Neznámý interpret"
		}
		return described{
			title: am.Title, sortTitle: am.Title, year: am.Year,
			artist: am.Artist, albumArtist: am.AlbumArtist, album: am.Album, genre: am.Genre,
			disc: am.Disc, track: am.Track, hasArt: am.HasPicture,
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
					video_codec = ?, audio_codec = ?, width = COALESCE(?, width), height = COALESCE(?, height),
					pix_fmt = ?, audio_channels = ? WHERE id = ?`,
					state, nullInt64(info.DurationMs), nullInt64(info.Bitrate), nullStr(info.Container),
					nullStr(info.VideoCodec), nullStr(info.AudioCodec), nullInt(info.Width), nullInt(info.Height),
					nullStr(info.PixFmt), nullInt(info.Channels), j.id)
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

func itoa(n int) string { return strconv.Itoa(n) }

func nullInt(n int) sql.NullInt64 { return sql.NullInt64{Int64: int64(n), Valid: n != 0} }

func nullInt64(n int64) sql.NullInt64 { return sql.NullInt64{Int64: n, Valid: n != 0} }

func nullIntIf(ok bool, n int) sql.NullInt64 { return sql.NullInt64{Int64: int64(n), Valid: ok} }

func nullStr(s string) sql.NullString { return sql.NullString{String: s, Valid: s != ""} }

func nullTime(t time.Time) sql.NullInt64 {
	return sql.NullInt64{Int64: t.Unix(), Valid: !t.IsZero()}
}
