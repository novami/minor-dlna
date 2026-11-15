package library

import (
	"context"
	"database/sql"
	"fmt"
	"strconv"
	"strings"
	"time"
)

const (
	classAlbum      = "object.container.album.musicAlbum"
	classArtist     = "object.container.person.musicArtist"
	classGenre      = "object.container.genre.musicGenre"
	classPhotoAlbum = "object.container.album.photoAlbum"
)

var months = []string{"Leden", "Únor", "Březen", "Duben", "Květen", "Červen", "Červenec", "Srpen", "Září", "Říjen", "Listopad", "Prosinec"}

// monthTitle turns "2023-05" into "Květen 2023".
func monthTitle(ym string) string {
	y, m, ok := parseYM(ym)
	if !ok {
		return ym
	}
	return months[m-1] + " " + strconv.Itoa(y)
}

func parseYM(ym string) (y, m int, ok bool) {
	ys, ms, found := strings.Cut(ym, "-")
	y, err1 := strconv.Atoi(ys)
	m, err2 := strconv.Atoi(ms)
	return y, m, found && err1 == nil && err2 == nil && m >= 1 && m <= 12
}

// photoDates serves "dates" (years), "py<year>" (months) and "pm<year>-<month>" (photos).
// Date ranges are computed in local time so the taken_at index can be used.
func (c *Catalog) photoDates(ctx context.Context, lib *Library, id, v string, start, count int) ([]Object, int, error) {
	lid := libID(lib)
	switch {
	case v == "dates":
		objs, total, err := c.groups(ctx, id, `SELECT CAST(strftime('%Y', taken_at, 'unixepoch', 'localtime') AS INTEGER) y, COUNT(*)
			FROM item WHERE library_id = ? AND taken_at IS NOT NULL GROUP BY y ORDER BY y DESC`,
			func(k int64) (string, string) {
				return lid + "/py" + strconv.FormatInt(k, 10), strconv.FormatInt(k, 10)
			},
			start, count, lib.ID)
		return objs, total, err
	case strings.HasPrefix(v, "py"):
		y, err := strconv.Atoi(v[2:])
		if err != nil {
			return nil, 0, ErrNotFound
		}
		from, to := time.Date(y, 1, 1, 0, 0, 0, 0, time.Local), time.Date(y+1, 1, 1, 0, 0, 0, 0, time.Local)
		objs, total, err := c.groups(ctx, id, `SELECT CAST(strftime('%m', taken_at, 'unixepoch', 'localtime') AS INTEGER) m, COUNT(*)
			FROM item WHERE library_id = ? AND taken_at >= ? AND taken_at < ? GROUP BY m ORDER BY m`,
			func(k int64) (string, string) {
				ym := fmt.Sprintf("%04d-%02d", y, k)
				return lid + "/pm" + ym, monthTitle(ym)
			}, start, count, lib.ID, from.Unix(), to.Unix())
		for i := range objs {
			objs[i].Class = classPhotoAlbum
		}
		return objs, total, err
	default:
		y, m, ok := parseYM(v[2:])
		if !ok {
			return nil, 0, ErrNotFound
		}
		from := time.Date(y, time.Month(m), 1, 0, 0, 0, 0, time.Local)
		to := from.AddDate(0, 1, 0)
		return c.itemPage(ctx, id, ctxFolder, `i.library_id = ? AND i.taken_at >= ? AND i.taken_at < ?`, "i.taken_at, i.sort_title",
			start, count, lib.ID, from.Unix(), to.Unix())
	}
}

// musicLists serves the artists, albums and genres views of a music library.
func (c *Catalog) musicLists(ctx context.Context, lib *Library, id, v string, start, count int) ([]Object, int, error) {
	var objs []Object
	var total int
	var err error
	switch v {
	case "artists":
		objs, total, err = c.groupsNamed(ctx, id, `SELECT ar.id, ar.name, COUNT(DISTINCT i.album_id) FROM artist ar
			JOIN item i ON i.artist_id = ar.id WHERE ar.library_id = ? GROUP BY ar.id ORDER BY ar.sort_name`, "A", start, count, lib.ID)
		setClass(objs, classArtist)
	case "genres":
		objs, total, err = c.groupsNamed(ctx, id, `SELECT g.id, g.name, COUNT(DISTINCT i.album_id) FROM genre g
			JOIN item i ON i.genre_id = g.id WHERE g.library_id = ? GROUP BY g.id ORDER BY g.sort_name`, "G", start, count, lib.ID)
		setClass(objs, classGenre)
	case "albums":
		objs, total, err = c.albums(ctx, id, `al.library_id = ?`, `al.sort_title`, start, count, lib.ID)
	}
	return objs, total, err
}

func setClass(objs []Object, class string) {
	for i := range objs {
		objs[i].Class = class
	}
}

// albums lists album containers with cover art taken from the first track that has one.
func (c *Catalog) albums(ctx context.Context, parent, where, order string, start, count int, args ...any) ([]Object, int, error) {
	rows, err := c.st.DB.QueryContext(ctx, `SELECT al.id, al.title, ar.name, COUNT(i.id), MIN(CASE WHEN i.has_art = 1 THEN i.id END)
		FROM album al LEFT JOIN artist ar ON ar.id = al.artist_id JOIN item i ON i.album_id = al.id
		WHERE `+where+` GROUP BY al.id ORDER BY `+order, args...)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()
	var out []Object
	for rows.Next() {
		var id int64
		var title string
		var artist sql.NullString
		var n int
		var art sql.NullInt64
		if err := rows.Scan(&id, &title, &artist, &n, &art); err != nil {
			return nil, 0, err
		}
		o := container("B"+strconv.FormatInt(id, 10), parent, title, n)
		o.Class, o.Artist = classAlbum, artist.String
		if art.Valid {
			o.ArtPath = ThumbPath(art.Int64, "tn")
		}
		out = append(out, o)
	}
	return page(out, start, count), len(out), rows.Err()
}

func (c *Catalog) musicChildren(ctx context.Context, id string, start, count int) ([]Object, int, error) {
	n, err := strconv.ParseInt(id[1:], 10, 64)
	if err != nil {
		return nil, 0, ErrNotFound
	}
	if _, err := c.musicMetadata(ctx, id, -1); err != nil {
		return nil, 0, err
	}
	switch id[0] {
	case 'A':
		return c.albums(ctx, id, `al.artist_id = ?`, `al.year, al.sort_title`, start, count, n)
	case 'G':
		return c.albums(ctx, id, `al.id IN (SELECT album_id FROM item WHERE genre_id = ?)`, `al.sort_title`, start, count, n)
	default:
		return c.itemPage(ctx, id, ctxFolder, `i.album_id = ?`, "COALESCE(i.disc, 1), COALESCE(i.track, 0), i.sort_title", start, count, n)
	}
}

func (c *Catalog) musicMetadata(ctx context.Context, id string, total int) (Object, error) {
	n, err := strconv.ParseInt(id[1:], 10, 64)
	if err != nil {
		return Object{}, ErrNotFound
	}
	var name string
	var lib int64
	var o Object
	switch id[0] {
	case 'A':
		err = c.st.DB.QueryRowContext(ctx, `SELECT name, library_id FROM artist WHERE id = ?`, n).Scan(&name, &lib)
		o = container(id, "L"+strconv.FormatInt(lib, 10)+"/artists", name, total)
		o.Class = classArtist
	case 'G':
		err = c.st.DB.QueryRowContext(ctx, `SELECT name, library_id FROM genre WHERE id = ?`, n).Scan(&name, &lib)
		o = container(id, "L"+strconv.FormatInt(lib, 10)+"/genres", name, total)
		o.Class = classGenre
	case 'B':
		var objs []Object
		objs, _, err = c.albums(ctx, "", `al.id = ?`, `al.id`, 0, 0, n)
		if err == nil && len(objs) == 1 {
			o = objs[0]
			_ = c.st.DB.QueryRowContext(ctx, `SELECT library_id FROM album WHERE id = ?`, n).Scan(&lib)
			o.ParentID = "L" + strconv.FormatInt(lib, 10) + "/albums"
			if total >= 0 {
				o.ChildCount = total
			}
		} else if err == nil {
			err = ErrNotFound
		}
	default:
		return Object{}, ErrNotFound
	}
	if err != nil {
		return Object{}, ErrNotFound
	}
	return o, nil
}
