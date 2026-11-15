// Package library indexes configured folders and exposes them as a browsable catalog.
//
// Object IDs are opaque to clients and never contain paths:
//
//	"0"                root
//	"L<id>"            library
//	"L<id>/<view>"     view of a library (all, recent, years, folders, shows), "L<id>/y<year>" one year
//	"D<id>"            folder
//	"S<id>"            show, "S<id>/<season>" season
//	"I<id>"            media item
package library

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/novami/minor-dlna/internal/config"
	"github.com/novami/minor-dlna/internal/dlna"
	"github.com/novami/minor-dlna/internal/store"
)

const (
	RootID      = "0"
	recentLimit = 50
)

var ErrNotFound = errors.New("no such object")

type Object struct {
	ID          string
	ParentID    string
	Title       string
	IsDir       bool
	ChildCount  int // -1 = unknown
	Path        string
	Size        int64
	ModTime     time.Time
	Year        int
	Format      dlna.Format
	MediaPath   string // URL path of the media resource, items only
	DurationMs  int64
	Width       int
	Height      int
	Orientation int
	Taken       time.Time
	Artist      string
	Album       string
	Genre       string
	Track       int
	ArtPath     string // URL path of a JPEG thumbnail, empty if none
	Class       string // container class override, default storageFolder
	Container   string // ffprobe format name
	VideoCodec  string
	AudioCodec  string
	PixFmt      string
	Channels    int
	Subtitle    string // path of an external .srt
}

type Library struct {
	ID    int64
	Name  string
	Type  config.LibraryType
	Paths []string
}

type Catalog struct {
	st   *store.Store
	libs []*Library
	byID map[int64]*Library
	// VideoThumbs enables thumbnails for video items (needs ffmpeg).
	VideoThumbs bool
}

// NewCatalog syncs configured libraries into the store.
func NewCatalog(ctx context.Context, st *store.Store, cfg []config.Library) (*Catalog, error) {
	m := map[string]string{}
	for _, l := range cfg {
		m[l.Name] = string(l.Type)
	}
	ids, err := st.SyncLibraries(ctx, m)
	if err != nil {
		return nil, err
	}
	c := &Catalog{st: st, byID: map[int64]*Library{}}
	for _, l := range cfg {
		lib := &Library{ID: ids[l.Name], Name: l.Name, Type: l.Type, Paths: l.Paths}
		c.libs = append(c.libs, lib)
		c.byID[lib.ID] = lib
	}
	return c, nil
}

func (c *Catalog) Libraries() []*Library { return c.libs }

func (c *Catalog) UpdateID(ctx context.Context) uint32 { return c.st.UpdateID(ctx) }

// view is a fixed container inside a library.
type view struct{ key, title string }

func views(t config.LibraryType) []view {
	switch t {
	case config.Movies:
		return []view{{"all", "Všechny filmy"}, {"recent", "Naposledy přidané"}, {"years", "Podle roku"}, {"folders", "Složky"}}
	case config.Shows:
		return []view{{"shows", "Seriály"}, {"recent", "Naposledy přidané"}, {"folders", "Složky"}}
	case config.Videos:
		return []view{{"folders", "Složky"}, {"recent", "Naposledy přidané"}}
	case config.Photos:
		return []view{{"dates", "Podle data"}, {"folders", "Složky"}}
	case config.Music:
		return []view{{"artists", "Interpreti"}, {"albums", "Alba"}, {"genres", "Žánry"}, {"folders", "Složky"}}
	}
	return nil
}

func container(id, parent, title string, count int) Object {
	return Object{ID: id, ParentID: parent, Title: title, IsDir: true, ChildCount: count}
}

// Metadata returns a single object.
func (c *Catalog) Metadata(ctx context.Context, id string) (Object, error) {
	if id == RootID {
		return container(RootID, "-1", "MinorDLNA", len(c.libs)), nil
	}
	_, total, err := c.Children(ctx, id, 0, 1)
	if err != nil && !errors.Is(err, errIsItem) {
		return Object{}, err
	}
	switch id[0] {
	case 'L':
		lib, v, err := c.parseLib(id)
		if err != nil {
			return Object{}, err
		}
		if v == "" {
			return container(id, RootID, lib.Name, total), nil
		}
		parent := libID(lib)
		title := v
		for _, vw := range views(lib.Type) {
			if vw.key == v {
				title = vw.title
			}
		}
		switch {
		case strings.HasPrefix(v, "py"):
			parent, title = libID(lib)+"/dates", v[2:]
		case strings.HasPrefix(v, "pm"):
			parent, title = libID(lib)+"/py"+v[2:6], monthTitle(v[2:])
		case strings.HasPrefix(v, "y"):
			parent, title = libID(lib)+"/years", v[1:]
		}
		return container(id, parent, title, total), nil
	case 'D':
		d, err := c.dir(ctx, id)
		if err != nil {
			return Object{}, err
		}
		return container(id, d.parentID, d.name, total), nil
	case 'S':
		showID, season, hasSeason, err := parseShow(id)
		if err != nil {
			return Object{}, err
		}
		var name string
		var lid int64
		if err := c.st.DB.QueryRowContext(ctx, `SELECT name, library_id FROM show WHERE id = ?`, showID).Scan(&name, &lid); err != nil {
			return Object{}, ErrNotFound
		}
		if hasSeason {
			return container(id, "S"+strconv.FormatInt(showID, 10), seasonTitle(season), total), nil
		}
		return container(id, "L"+strconv.FormatInt(lid, 10)+"/shows", name, total), nil
	case 'A', 'B', 'G':
		return c.musicMetadata(ctx, id, total)
	case 'I':
		n, err := strconv.ParseInt(id[1:], 10, 64)
		if err != nil {
			return Object{}, ErrNotFound
		}
		objs, err := c.items(ctx, "", ctxFolder, `i.id = ?`, "i.id", 0, 1, n)
		if err != nil || len(objs) == 0 {
			return Object{}, ErrNotFound
		}
		return objs[0], nil
	}
	return Object{}, ErrNotFound
}

var errIsItem = errors.New("item has no children")

// Children returns direct children of a container with paging; count 0 = all.
func (c *Catalog) Children(ctx context.Context, id string, start, count int) ([]Object, int, error) {
	if id == RootID {
		var out []Object
		for _, l := range c.libs {
			out = append(out, container(libID(l), RootID, l.Name, -1))
		}
		return page(out, start, count), len(out), nil
	}
	if id == "" {
		return nil, 0, ErrNotFound
	}
	switch id[0] {
	case 'L':
		lib, v, err := c.parseLib(id)
		if err != nil {
			return nil, 0, err
		}
		return c.libChildren(ctx, lib, id, v, start, count)
	case 'D':
		d, err := c.dir(ctx, id)
		if err != nil {
			return nil, 0, err
		}
		return c.dirChildren(ctx, id, d.id, start, count)
	case 'S':
		showID, season, hasSeason, err := parseShow(id)
		if err != nil {
			return nil, 0, err
		}
		if hasSeason {
			return c.itemPage(ctx, id, ctxSeason, `i.show_id = ? AND i.season = ?`, "i.episode, i.sort_title", start, count, showID, season)
		}
		return c.seasons(ctx, id, showID, start, count)
	case 'A', 'B', 'G':
		return c.musicChildren(ctx, id, start, count)
	case 'I':
		return nil, 0, errIsItem
	}
	return nil, 0, ErrNotFound
}

func (c *Catalog) libChildren(ctx context.Context, lib *Library, id, v string, start, count int) ([]Object, int, error) {
	lid := lib.ID
	switch {
	case v == "":
		vs := views(lib.Type)
		if vs == nil {
			return c.folders(ctx, lib, id, start, count)
		}
		out := make([]Object, 0, len(vs))
		for _, vw := range vs {
			out = append(out, container(id+"/"+vw.key, id, vw.title, -1))
		}
		return page(out, start, count), len(out), nil
	case v == "folders":
		return c.folders(ctx, lib, id, start, count)
	case v == "all":
		return c.itemPage(ctx, id, ctxMovie, `i.library_id = ?`, "i.sort_title", start, count, lid)
	case v == "recent":
		if start >= recentLimit {
			return nil, 0, nil
		}
		if count == 0 || start+count > recentLimit {
			count = recentLimit - start
		}
		objs, total, err := c.itemPage(ctx, id, ctxRecent, `i.library_id = ?`, "i.added_at DESC, i.id DESC", start, count, lid)
		return objs, min(total, recentLimit), err
	case v == "years":
		return c.groups(ctx, id, `SELECT year, COUNT(*) FROM item WHERE library_id = ? AND year IS NOT NULL GROUP BY year ORDER BY year DESC`,
			func(k int64) (string, string) {
				return id[:strings.Index(id, "/")] + "/y" + strconv.FormatInt(k, 10), strconv.FormatInt(k, 10)
			},
			start, count, lid)
	case strings.HasPrefix(v, "y"):
		year, err := strconv.Atoi(v[1:])
		if err != nil {
			return nil, 0, ErrNotFound
		}
		return c.itemPage(ctx, id, ctxMovie, `i.library_id = ? AND i.year = ?`, "i.sort_title", start, count, lid, year)
	case v == "dates", strings.HasPrefix(v, "py"), strings.HasPrefix(v, "pm"):
		return c.photoDates(ctx, lib, id, v, start, count)
	case v == "artists", v == "albums", v == "genres":
		return c.musicLists(ctx, lib, id, v, start, count)
	case v == "shows":
		return c.groupsNamed(ctx, id, `SELECT s.id, s.name, COUNT(i.id) FROM show s JOIN item i ON i.show_id = s.id
			WHERE s.library_id = ? GROUP BY s.id ORDER BY s.sort_name`, "S", start, count, lid)
	}
	return nil, 0, ErrNotFound
}

// folders lists the library folder roots: the single root's contents, or one container per configured path.
func (c *Catalog) folders(ctx context.Context, lib *Library, id string, start, count int) ([]Object, int, error) {
	if len(lib.Paths) == 1 {
		var dirID int64
		err := c.st.DB.QueryRowContext(ctx, `SELECT id FROM dir WHERE library_id = ? AND root = 0 AND rel = ''`, lib.ID).Scan(&dirID)
		if errors.Is(err, sql.ErrNoRows) {
			return nil, 0, nil
		}
		if err != nil {
			return nil, 0, err
		}
		return c.dirChildren(ctx, id, dirID, start, count)
	}
	return c.groupsNamed(ctx, id, `SELECT id, name, -1 FROM dir WHERE library_id = ? AND parent_id IS NULL ORDER BY root`, "D", start, count, lib.ID)
}

func (c *Catalog) dirChildren(ctx context.Context, id string, dirID int64, start, count int) ([]Object, int, error) {
	var nDirs int
	if err := c.st.DB.QueryRowContext(ctx, `SELECT COUNT(*) FROM dir WHERE parent_id = ?`, dirID).Scan(&nDirs); err != nil {
		return nil, 0, err
	}
	var out []Object
	if start < nDirs {
		limit := nDirs - start
		if count > 0 {
			limit = min(limit, count)
		}
		rows, err := c.st.DB.QueryContext(ctx, `SELECT id, name FROM dir WHERE parent_id = ? ORDER BY sort_name LIMIT ? OFFSET ?`, dirID, limit, start)
		if err != nil {
			return nil, 0, err
		}
		for rows.Next() {
			var did int64
			var name string
			if err := rows.Scan(&did, &name); err != nil {
				rows.Close()
				return nil, 0, err
			}
			out = append(out, container("D"+strconv.FormatInt(did, 10), id, name, -1))
		}
		rows.Close()
	}
	itemStart := max(start-nDirs, 0)
	itemCount := 0
	if count > 0 {
		itemCount = count - len(out)
		if itemCount == 0 {
			// Page filled by folders; still need the total.
			var n int
			err := c.st.DB.QueryRowContext(ctx, `SELECT COUNT(*) FROM item WHERE dir_id = ?`, dirID).Scan(&n)
			return out, nDirs + n, err
		}
	}
	items, nItems, err := c.itemPage(ctx, id, ctxFolder, `i.dir_id = ?`, "i.sort_title", itemStart, itemCount, dirID)
	if err != nil {
		return nil, 0, err
	}
	return append(out, items...), nDirs + nItems, nil
}

func (c *Catalog) seasons(ctx context.Context, id string, showID int64, start, count int) ([]Object, int, error) {
	return c.groups(ctx, id, `SELECT COALESCE(season, 0), COUNT(*) FROM item WHERE show_id = ? GROUP BY 1 ORDER BY 1`,
		func(k int64) (string, string) { return id + "/" + strconv.FormatInt(k, 10), seasonTitle(int(k)) },
		start, count, showID)
}

func seasonTitle(n int) string {
	if n == 0 {
		return "Speciály"
	}
	return fmt.Sprintf("Série %d", n)
}

// groups lists containers from a "key, count" query.
func (c *Catalog) groups(ctx context.Context, parent, q string, mk func(int64) (string, string), start, count int, args ...any) ([]Object, int, error) {
	rows, err := c.st.DB.QueryContext(ctx, q, args...)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()
	var out []Object
	for rows.Next() {
		var k int64
		var n int
		if err := rows.Scan(&k, &n); err != nil {
			return nil, 0, err
		}
		id, title := mk(k)
		out = append(out, container(id, parent, title, n))
	}
	return page(out, start, count), len(out), rows.Err()
}

// groupsNamed lists containers from an "id, name, count" query.
func (c *Catalog) groupsNamed(ctx context.Context, parent, q, prefix string, start, count int, args ...any) ([]Object, int, error) {
	rows, err := c.st.DB.QueryContext(ctx, q, args...)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()
	var out []Object
	for rows.Next() {
		var k int64
		var name string
		var n int
		if err := rows.Scan(&k, &name, &n); err != nil {
			return nil, 0, err
		}
		out = append(out, container(prefix+strconv.FormatInt(k, 10), parent, name, n))
	}
	return page(out, start, count), len(out), rows.Err()
}

// titleCtx selects how an item title is displayed.
type titleCtx int

const (
	ctxFolder titleCtx = iota
	ctxMovie
	ctxSeason
	ctxRecent
)

func (c *Catalog) itemPage(ctx context.Context, parent string, tc titleCtx, where, order string, start, count int, args ...any) ([]Object, int, error) {
	var total int
	if err := c.st.DB.QueryRowContext(ctx, `SELECT COUNT(*) FROM item i WHERE `+where, args...).Scan(&total); err != nil {
		return nil, 0, err
	}
	limit := -1
	if count > 0 {
		limit = count
	}
	objs, err := c.items(ctx, parent, tc, where, order, start, limit, args...)
	return objs, total, err
}

func (c *Catalog) items(ctx context.Context, parent string, tc titleCtx, where, order string, start, limit int, args ...any) ([]Object, error) {
	q := `SELECT i.id, i.library_id, i.dir_id, i.path, i.name, i.mime, i.kind, i.size, i.mtime, i.title, i.year,
		i.season, i.episode, i.episode_title, i.duration_ms, i.width, i.height, s.name,
		i.orientation, i.taken_at, i.artist, al.title, g.name, i.track, i.has_art,
		i.container, i.video_codec, i.audio_codec, i.pix_fmt, i.audio_channels, i.subtitle
		FROM item i LEFT JOIN show s ON s.id = i.show_id LEFT JOIN album al ON al.id = i.album_id
		LEFT JOIN genre g ON g.id = i.genre_id WHERE ` + where + ` ORDER BY ` + order + ` LIMIT ? OFFSET ?`
	rows, err := c.st.DB.QueryContext(ctx, q, append(args, limit, start)...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Object
	for rows.Next() {
		var (
			o                       Object
			id, libID, dirID, mtime int64
			kind                    int
			name, mime              string
			year, season, episode   sql.NullInt64
			dur, w, h               sql.NullInt64
			epTitle, show           sql.NullString
			orient, taken, track    sql.NullInt64
			artist, album, genre    sql.NullString
			hasArt                  bool
			cont, vc, ac, pix, sub  sql.NullString
			channels                sql.NullInt64
		)
		if err := rows.Scan(&id, &libID, &dirID, &o.Path, &name, &mime, &kind, &o.Size, &mtime, &o.Title, &year,
			&season, &episode, &epTitle, &dur, &w, &h, &show,
			&orient, &taken, &artist, &album, &genre, &track, &hasArt,
			&cont, &vc, &ac, &pix, &channels, &sub); err != nil {
			return nil, err
		}
		o.Container, o.VideoCodec, o.AudioCodec, o.PixFmt = cont.String, vc.String, ac.String, pix.String
		o.Channels, o.Subtitle = int(channels.Int64), sub.String
		o.Orientation, o.Track = int(orient.Int64), int(track.Int64)
		o.Artist, o.Album, o.Genre = artist.String, album.String, genre.String
		if taken.Valid {
			o.Taken = time.Unix(taken.Int64, 0)
		}
		if hasArt || (dlna.Kind(kind) == dlna.Video && c.VideoThumbs) {
			o.ArtPath = ThumbPath(id, "tn")
		}
		o.ID = "I" + strconv.FormatInt(id, 10)
		o.ParentID = parent
		if parent == "" {
			o.ParentID = "D" + strconv.FormatInt(dirID, 10)
		}
		o.ModTime = time.Unix(mtime, 0)
		o.Year = int(year.Int64)
		o.Format = dlna.Format{Kind: dlna.Kind(kind), Mime: mime}
		o.MediaPath = "/media/" + strconv.FormatInt(id, 10) + strings.ToLower(filepath.Ext(name))
		o.DurationMs, o.Width, o.Height = dur.Int64, int(w.Int64), int(h.Int64)
		if c.byID[libID] != nil {
			o.Title = displayTitle(c.byID[libID].Type, tc, o.Title, int(year.Int64), show.String, int(season.Int64), int(episode.Int64), epTitle.String, show.Valid)
		}
		out = append(out, o)
	}
	return out, rows.Err()
}

func displayTitle(lt config.LibraryType, tc titleCtx, title string, year int, show string, season, episode int, epTitle string, isEpisode bool) string {
	switch {
	case lt == config.Movies && year > 0:
		return fmt.Sprintf("%s (%d)", title, year)
	case lt == config.Shows && isEpisode:
		code := fmt.Sprintf("S%02dE%02d", season, episode)
		if tc == ctxSeason {
			code = fmt.Sprintf("%02d.", episode)
		} else if tc == ctxRecent || tc == ctxFolder {
			code = show + " " + code
		}
		if epTitle != "" {
			return code + " " + epTitle
		}
		return code
	}
	return title
}

// ResolveMedia maps a media URL path (without the /media/ prefix, e.g. "123.mkv") to an item.
func (c *Catalog) ResolveMedia(ctx context.Context, p string) (Object, error) {
	idStr := strings.TrimSuffix(p, filepath.Ext(p))
	if _, err := strconv.ParseInt(idStr, 10, 64); err != nil {
		return Object{}, ErrNotFound
	}
	return c.Metadata(ctx, "I"+idStr)
}

func (c *Catalog) parseLib(id string) (*Library, string, error) {
	head, v, _ := strings.Cut(id[1:], "/")
	n, err := strconv.ParseInt(head, 10, 64)
	if err != nil || c.byID[n] == nil {
		return nil, "", ErrNotFound
	}
	return c.byID[n], v, nil
}

type dirRow struct {
	id, libID      int64
	name, parentID string
}

func (c *Catalog) dir(ctx context.Context, id string) (dirRow, error) {
	n, err := strconv.ParseInt(id[1:], 10, 64)
	if err != nil {
		return dirRow{}, ErrNotFound
	}
	d := dirRow{id: n}
	var parent sql.NullInt64
	var rel string
	if err := c.st.DB.QueryRowContext(ctx, `SELECT library_id, name, parent_id, rel FROM dir WHERE id = ?`, n).Scan(&d.libID, &d.name, &parent, &rel); err != nil {
		return dirRow{}, ErrNotFound
	}
	lib := c.byID[d.libID]
	if lib == nil {
		return dirRow{}, ErrNotFound
	}
	folders := libID(lib)
	if views(lib.Type) != nil {
		folders += "/folders"
	}
	switch {
	case parent.Valid && !(len(lib.Paths) == 1 && isRootDir(ctx, c, parent.Int64)):
		d.parentID = "D" + strconv.FormatInt(parent.Int64, 10)
	default:
		d.parentID = folders
	}
	return d, nil
}

func isRootDir(ctx context.Context, c *Catalog, id int64) bool {
	var rel string
	_ = c.st.DB.QueryRowContext(ctx, `SELECT rel FROM dir WHERE id = ?`, id).Scan(&rel)
	return rel == ""
}

func parseShow(id string) (showID int64, season int, hasSeason bool, err error) {
	head, s, hasSeason := strings.Cut(id[1:], "/")
	showID, err = strconv.ParseInt(head, 10, 64)
	if err != nil {
		return 0, 0, false, ErrNotFound
	}
	if hasSeason {
		if season, err = strconv.Atoi(s); err != nil {
			return 0, 0, false, ErrNotFound
		}
	}
	return showID, season, hasSeason, nil
}

func libID(l *Library) string { return "L" + strconv.FormatInt(l.ID, 10) }

func page(objs []Object, start, count int) []Object {
	start = min(start, len(objs))
	end := len(objs)
	if count > 0 {
		end = min(start+count, end)
	}
	return objs[start:end]
}

// NaturalCompare orders strings case-insensitively with numbers compared by value.
func NaturalCompare(a, b string) int { return strings.Compare(SortKey(a), SortKey(b)) }

// ThumbPath is the URL path of a generated JPEG for an item: size tn, sm or lrg.
func ThumbPath(itemID int64, size string) string {
	return "/thumb/" + strconv.FormatInt(itemID, 10) + "/" + size + ".jpg"
}
