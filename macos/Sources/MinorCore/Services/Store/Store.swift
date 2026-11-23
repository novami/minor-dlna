import Foundation

/// The media index in SQLite (WAL): one connection writes (scanner), another reads (Browse), so a scan never blocks the TV.
public final class Store: Sendable {
	let writer: Database
	let reader: Database

	public static var defaultURL: URL { AppPaths.support.appending(path: "library.sqlite") }

	public init(url: URL = Store.defaultURL) throws {
		try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
		writer = try Database(path: url.path)
		try writer.execute("PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL")
		try Self.migrate(writer)
		reader = try Database(path: url.path)
	}

	/// Each entry upgrades the schema by one user_version.
	static let migrations = [
		"""
		CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
		CREATE TABLE library (
			id   INTEGER PRIMARY KEY,
			uuid TEXT NOT NULL UNIQUE,
			type TEXT NOT NULL
		);
		CREATE TABLE dir (
			id         INTEGER PRIMARY KEY,
			library_id INTEGER NOT NULL REFERENCES library ON DELETE CASCADE,
			root       TEXT NOT NULL,
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
		CREATE TABLE artist (
			id         INTEGER PRIMARY KEY,
			library_id INTEGER NOT NULL REFERENCES library ON DELETE CASCADE,
			name       TEXT NOT NULL,
			sort_name  TEXT NOT NULL,
			UNIQUE (library_id, name)
		);
		CREATE TABLE album (
			id         INTEGER PRIMARY KEY,
			library_id INTEGER NOT NULL REFERENCES library ON DELETE CASCADE,
			artist_id  INTEGER NOT NULL REFERENCES artist ON DELETE CASCADE,
			title      TEXT NOT NULL,
			sort_title TEXT NOT NULL,
			year       INTEGER,
			UNIQUE (library_id, artist_id, title)
		);
		CREATE INDEX album_artist ON album (artist_id, sort_title);
		CREATE TABLE genre (
			id         INTEGER PRIMARY KEY,
			library_id INTEGER NOT NULL REFERENCES library ON DELETE CASCADE,
			name       TEXT NOT NULL,
			sort_name  TEXT NOT NULL,
			UNIQUE (library_id, name)
		);
		CREATE TABLE item (
			id             INTEGER PRIMARY KEY,
			library_id     INTEGER NOT NULL REFERENCES library ON DELETE CASCADE,
			dir_id         INTEGER NOT NULL REFERENCES dir ON DELETE CASCADE,
			path           TEXT NOT NULL,
			name           TEXT NOT NULL,
			mime           TEXT NOT NULL,
			size           INTEGER NOT NULL,
			mtime          INTEGER NOT NULL,
			added_at       INTEGER NOT NULL,
			title          TEXT NOT NULL,
			sort_title     TEXT NOT NULL,
			year           INTEGER,
			show_id        INTEGER REFERENCES show ON DELETE SET NULL,
			season         INTEGER,
			episode        INTEGER,
			episode_title  TEXT,
			subtitle       TEXT,
			taken_at       INTEGER,
			orientation    INTEGER,
			artist         TEXT,
			artist_id      INTEGER REFERENCES artist ON DELETE SET NULL,
			album_id       INTEGER REFERENCES album ON DELETE SET NULL,
			genre_id       INTEGER REFERENCES genre ON DELETE SET NULL,
			disc           INTEGER,
			track          INTEGER,
			has_art        INTEGER NOT NULL DEFAULT 0,
			-- technical details from ffprobe; probed: 0 pending, 1 done, 2 failed (retried when the file changes)
			probed         INTEGER NOT NULL DEFAULT 0,
			duration_ms    INTEGER,
			width          INTEGER,
			height         INTEGER,
			bitrate        INTEGER,
			container      TEXT,
			video_codec    TEXT,
			audio_codec    TEXT,
			pix_fmt        TEXT,
			audio_channels INTEGER,
			UNIQUE (library_id, path)
		);
		CREATE INDEX item_dir ON item (dir_id, sort_title);
		CREATE INDEX item_title ON item (library_id, sort_title);
		CREATE INDEX item_added ON item (library_id, added_at);
		CREATE INDEX item_year ON item (library_id, year);
		CREATE INDEX item_show ON item (show_id, season, episode);
		CREATE INDEX item_taken ON item (library_id, taken_at);
		CREATE INDEX item_album ON item (album_id, disc, track);
		CREATE INDEX item_artist ON item (artist_id);
		CREATE INDEX item_genre ON item (genre_id);
		CREATE INDEX item_probe ON item (probed);
		""",
		"""
		-- A movie (file title|year) or show (name|) matched to Wikidata; status: 0 not found yet, 1 automatic, 2 by hand, 3 none by hand
		CREATE TABLE title_match (
			id         INTEGER PRIMARY KEY,
			kind       TEXT NOT NULL,
			query      TEXT NOT NULL,
			status     INTEGER NOT NULL DEFAULT 0,
			wikidata   TEXT,
			title      TEXT,
			sort_title TEXT,
			orig_title TEXT,
			year       INTEGER,
			overview   TEXT,
			genres     TEXT,
			director   TEXT,
			cast       TEXT,
			runtime    INTEGER,
			poster     INTEGER NOT NULL DEFAULT 0,
			checked_at INTEGER NOT NULL DEFAULT 0,
			UNIQUE (kind, query)
		);
		""",
		"""
		-- Watch progress keyed by file path (survives reindexing) and TVs found on the network.
		CREATE TABLE play_state (
			path        TEXT PRIMARY KEY,
			position_ms INTEGER NOT NULL DEFAULT 0,
			duration_ms INTEGER NOT NULL DEFAULT 0,
			watched     INTEGER NOT NULL DEFAULT 0,
			updated_at  INTEGER NOT NULL
		);
		CREATE TABLE renderer (
			udn      TEXT PRIMARY KEY,
			name     TEXT NOT NULL,
			maker    TEXT NOT NULL DEFAULT '',
			model    TEXT NOT NULL DEFAULT '',
			location TEXT NOT NULL,
			ip       TEXT NOT NULL,
			mac      TEXT NOT NULL DEFAULT '',
			seen_at  INTEGER NOT NULL
		);
		""",
	]

	static func migrate(_ db: Database) throws {
		let version = try db.one("PRAGMA user_version") { $0.int(0) } ?? 0
		guard version <= migrations.count else {
			throw SQLiteError(code: 0, message: "index is from a newer version (schema \(version))")
		}
		for i in version..<migrations.count {
			try db.transaction {
				try db.execute(migrations[i])
				try db.execute("PRAGMA user_version = \(i + 1)")
			}
		}
	}

	/// ContentDirectory SystemUpdateID.
	public func updateID() -> UInt32 {
		UInt32((try? reader.one("SELECT CAST(value AS INTEGER) FROM meta WHERE key = 'update_id'") { $0.int64(0) }) ?? 0)
	}

	/// Increments SystemUpdateID (wrapping to 1) and returns it.
	@discardableResult
	func bumpUpdateID() throws -> UInt32 {
		let v = try writer.one("""
			INSERT INTO meta (key, value) VALUES ('update_id', '1')
			ON CONFLICT (key) DO UPDATE SET value = CAST(value AS INTEGER) % 4294967295 + 1
			RETURNING CAST(value AS INTEGER)
			""") { $0.int64(0) }
		return UInt32(v ?? 0)
	}

	/// Makes the library table match the settings; returns library UUID → row id.
	/// A library whose type changed is indexed again from scratch, as titles are parsed per type.
	func syncLibraries(_ libs: [Library]) throws -> [UUID: Int64] {
		try writer.transaction {
			let rows = try writer.query("SELECT id, uuid, type FROM library") { ($0.int64(0), $0.text(1), $0.text(2)) }
			var ids: [UUID: Int64] = [:]
			for (id, uuid, type) in rows {
				if let lib = libs.first(where: { $0.id.uuidString == uuid }), lib.type.rawValue == type {
					ids[lib.id] = id
				} else {
					try writer.run("DELETE FROM library WHERE id = ?", id)
				}
			}
			for lib in libs where ids[lib.id] == nil {
				ids[lib.id] = try writer.one("INSERT INTO library (uuid, type) VALUES (?, ?) RETURNING id",
				                             lib.id.uuidString, lib.type.rawValue) { $0.int64(0) }
			}
			return ids
		}
	}
}
