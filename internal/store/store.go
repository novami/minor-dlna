// Package store keeps the media index in SQLite.
package store

import (
	"context"
	"database/sql"
	"fmt"
	"strconv"

	_ "modernc.org/sqlite"
)

type Store struct {
	DB *sql.DB
}

var migrations = []string{
	`CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
	CREATE TABLE library (
		id   INTEGER PRIMARY KEY,
		name TEXT NOT NULL UNIQUE,
		type TEXT NOT NULL
	);
	CREATE TABLE dir (
		id         INTEGER PRIMARY KEY,
		library_id INTEGER NOT NULL REFERENCES library ON DELETE CASCADE,
		root       INTEGER NOT NULL,
		rel        TEXT NOT NULL,
		parent_id  INTEGER REFERENCES dir ON DELETE CASCADE,
		name       TEXT NOT NULL,
		sort_name  TEXT NOT NULL,
		UNIQUE (library_id, root, rel)
	);
	CREATE INDEX dir_parent ON dir (parent_id, sort_name);
	CREATE TABLE show (
		id         INTEGER PRIMARY KEY,
		library_id INTEGER NOT NULL REFERENCES library ON DELETE CASCADE,
		name       TEXT NOT NULL,
		sort_name  TEXT NOT NULL,
		UNIQUE (library_id, name)
	);
	CREATE TABLE item (
		id            INTEGER PRIMARY KEY,
		library_id    INTEGER NOT NULL REFERENCES library ON DELETE CASCADE,
		dir_id        INTEGER NOT NULL REFERENCES dir ON DELETE CASCADE,
		path          TEXT NOT NULL,
		name          TEXT NOT NULL,
		kind          INTEGER NOT NULL,
		mime          TEXT NOT NULL,
		size          INTEGER NOT NULL,
		mtime         INTEGER NOT NULL,
		added_at      INTEGER NOT NULL,
		title         TEXT NOT NULL,
		sort_title    TEXT NOT NULL,
		year          INTEGER,
		show_id       INTEGER REFERENCES show ON DELETE SET NULL,
		season        INTEGER,
		episode       INTEGER,
		episode_title TEXT,
		duration_ms   INTEGER,
		width         INTEGER,
		height        INTEGER,
		container     TEXT,
		video_codec   TEXT,
		audio_codec   TEXT,
		bitrate       INTEGER,
		probed        INTEGER NOT NULL DEFAULT 0,
		UNIQUE (library_id, path)
	);
	CREATE INDEX item_dir ON item (dir_id, sort_title);
	CREATE INDEX item_title ON item (library_id, sort_title);
	CREATE INDEX item_added ON item (library_id, added_at);
	CREATE INDEX item_year ON item (library_id, year);
	CREATE INDEX item_show ON item (show_id, season, episode);
	CREATE INDEX item_probe ON item (probed);`,
}

// Open opens (and migrates) the database at path.
func Open(path string) (*Store, error) {
	dsn := "file:" + path + "?_pragma=foreign_keys(1)&_pragma=journal_mode(WAL)&_pragma=busy_timeout(5000)&_pragma=synchronous(NORMAL)"
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, err
	}
	s := &Store{DB: db}
	if err := s.migrate(); err != nil {
		db.Close()
		return nil, fmt.Errorf("migrate: %w", err)
	}
	return s, nil
}

func (s *Store) Close() error { return s.DB.Close() }

func (s *Store) migrate() error {
	var v int
	if err := s.DB.QueryRow(`PRAGMA user_version`).Scan(&v); err != nil {
		return err
	}
	for i := v; i < len(migrations); i++ {
		tx, err := s.DB.Begin()
		if err != nil {
			return err
		}
		if _, err := tx.Exec(migrations[i]); err != nil {
			tx.Rollback()
			return fmt.Errorf("migration %d: %w", i+1, err)
		}
		if _, err := tx.Exec(`PRAGMA user_version = ` + strconv.Itoa(i+1)); err != nil {
			tx.Rollback()
			return err
		}
		if err := tx.Commit(); err != nil {
			return err
		}
	}
	return nil
}

// UpdateID returns the ContentDirectory SystemUpdateID.
func (s *Store) UpdateID(ctx context.Context) uint32 {
	var v string
	if err := s.DB.QueryRowContext(ctx, `SELECT value FROM meta WHERE key = 'update_id'`).Scan(&v); err != nil {
		return 0
	}
	n, _ := strconv.ParseUint(v, 10, 32)
	return uint32(n)
}

// BumpUpdateID increments SystemUpdateID and returns the new value.
func (s *Store) BumpUpdateID(ctx context.Context) (uint32, error) {
	var v uint32
	err := s.DB.QueryRowContext(ctx, `INSERT INTO meta (key, value) VALUES ('update_id', '1')
		ON CONFLICT (key) DO UPDATE SET value = CAST(value AS INTEGER) % 4294967295 + 1
		RETURNING CAST(value AS INTEGER)`).Scan(&v)
	return v, err
}

// SyncLibraries makes the library table match the configured names and types; returns name → id.
func (s *Store) SyncLibraries(ctx context.Context, libs map[string]string) (map[string]int64, error) {
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	rows, err := tx.QueryContext(ctx, `SELECT id, name FROM library`)
	if err != nil {
		return nil, err
	}
	ids := map[string]int64{}
	var stale []int64
	for rows.Next() {
		var id int64
		var name string
		if err := rows.Scan(&id, &name); err != nil {
			rows.Close()
			return nil, err
		}
		if _, ok := libs[name]; ok {
			ids[name] = id
		} else {
			stale = append(stale, id)
		}
	}
	rows.Close()
	for _, id := range stale {
		if _, err := tx.ExecContext(ctx, `DELETE FROM library WHERE id = ?`, id); err != nil {
			return nil, err
		}
	}
	for name, typ := range libs {
		var id int64
		err := tx.QueryRowContext(ctx, `INSERT INTO library (name, type) VALUES (?, ?)
			ON CONFLICT (name) DO UPDATE SET type = excluded.type RETURNING id`, name, typ).Scan(&id)
		if err != nil {
			return nil, err
		}
		ids[name] = id
	}
	return ids, tx.Commit()
}
