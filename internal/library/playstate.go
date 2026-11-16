package library

import (
	"context"
	"strconv"
	"time"
)

// WatchedRatio: played this far counts as watched and the saved position is cleared.
const WatchedRatio = 0.9

// SavePosition records how far item id was played.
func (c *Catalog) SavePosition(ctx context.Context, id string, posMs, durMs int64) error {
	o, err := c.Metadata(ctx, id)
	if err != nil {
		return err
	}
	if durMs <= 0 {
		durMs = o.DurationMs
	}
	watched := durMs > 0 && float64(posMs) >= WatchedRatio*float64(durMs)
	if watched {
		posMs = 0
	}
	_, err = c.st.DB.ExecContext(ctx, `INSERT INTO play_state (path, position_ms, duration_ms, watched, updated_at)
		VALUES (?, ?, ?, ?, ?)
		ON CONFLICT (path) DO UPDATE SET position_ms = excluded.position_ms, duration_ms = excluded.duration_ms,
			watched = MAX(watched, excluded.watched), updated_at = excluded.updated_at`,
		o.Path, max(posMs, 0), durMs, watched, time.Now().Unix())
	return err
}

// NextEpisode returns the episode after item id in the same show, if any.
func (c *Catalog) NextEpisode(ctx context.Context, id string) (Object, bool) {
	n, err := strconv.ParseInt(id[1:], 10, 64)
	if err != nil || id[0] != 'I' {
		return Object{}, false
	}
	objs, err := c.items(ctx, "", ctxRecent, `i.show_id = (SELECT show_id FROM item WHERE id = ?)
		AND (i.season, i.episode) > (SELECT COALESCE(season, 0), COALESCE(episode, 0) FROM item WHERE id = ?)`,
		"i.season, i.episode", 0, 1, n, n)
	if err != nil || len(objs) == 0 {
		return Object{}, false
	}
	return objs[0], true
}
