import Foundation
import Synchronization

/// One matched (or unmatched) movie or show, for the settings window.
nonisolated struct MetaEntry: Sendable, Equatable, Identifiable {
	enum Status: Int, Sendable {
		case pending = 0, auto, manual, none
	}

	var id: Int64
	var isShow: Bool
	var fileTitle: String
	var fileYear: Int?
	var status: Status
	var title: String?
	var year: Int?
	var wikidata: String?
	/// Small poster on disk.
	var poster: URL?
	/// Looked up at least once.
	var checked: Bool
}

/// Matches movie titles and shows to Wikidata, keeps Czech titles, overviews and posters,
/// looks up new titles after each scan and refreshes old matches monthly.
nonisolated final class MetadataService: BackgroundService {
	static let refreshAfter: TimeInterval = 30 * 24 * 3600
	static let retryAfter: TimeInterval = 7 * 24 * 3600
	static let passInterval = Duration.seconds(6 * 3600)
	/// Between lookups, to be gentle to the free APIs.
	static let pause = Duration.milliseconds(300)
	/// In the caches: clearing the cache (or macOS purging it) only means downloading the posters again.
	static var defaultDir: URL { AppPaths.caches.appending(path: "posters", directoryHint: .isDirectory) }

	let store: Store
	let dir: URL
	let client: WikidataClient
	let onChange: @Sendable () -> Void
	private let kicked = Mutex(true)
	/// One lookup at a time: background pass vs. a match by hand.
	private let lock = AsyncSemaphore(1)

	init(store: Store, dir: URL = MetadataService.defaultDir, client: WikidataClient = .init(), onChange: @escaping @Sendable () -> Void) {
		self.store = store
		self.dir = dir
		self.client = client
		self.onChange = onChange
	}

	/// Requests a pass, e.g. after a library scan.
	func kick() { kicked.withLock { $0 = true } }

	func run() async {
		// Posters deleted from outside (macOS purging the caches) come back at once.
		try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		let watcher = FolderWatcher(paths: [FolderWatcher.realPath(dir.deletingLastPathComponent().path)], latency: 3) { [weak self] _ in
			guard let self, (try? self.refetchMissingPosters()) == true else { return }
			self.kick()
		}
		defer { withExtendedLifetime(watcher) {} }
		do {
			var last = ContinuousClock.now
			while !Task.isCancelled {
				let due = self.kicked.withLock { k in defer { k = false }; return k } || ContinuousClock.now - last >= Self.passInterval
				if due {
					last = .now
					do { try await self.pass() } catch where !Task.isCancelled {
						AppLog.library.warning("metadata lookup stopped: \(error, privacy: .public)")
					} catch {}
				}
				try? await Task.sleep(for: .seconds(2))
			}
		}
	}

	private struct Row {
		var id: Int64
		var kind: MetaKind
		var query: String
		var status: MetaEntry.Status
		var wikidata: String?
	}

	static func split(_ query: String) -> (title: String, year: Int?) {
		guard let i = query.lastIndex(of: "|") else { return (query, nil) }
		return (String(query[..<i]), Int(query[query.index(after: i)...]))
	}

	func pass() async throws {
		try sync()
		let now = Date().timeIntervalSince1970
		let due = try store.reader.query("""
			SELECT id, kind, query, status, wikidata FROM title_match
			WHERE (status = 0 AND checked_at < ?) OR (status IN (1, 2) AND checked_at < ?) ORDER BY checked_at, id
			""", Int64(now - Self.retryAfter), Int64(now - Self.refreshAfter)) { r in
			Row(id: r.int64(0), kind: MetaKind(rawValue: r.text(1)) ?? .movies, query: r.text(2),
			    status: MetaEntry.Status(rawValue: r.int(3)) ?? .pending, wikidata: r.optText(4))
		}
		guard !due.isEmpty else { return }
		AppLog.library.info("looking up metadata of \(due.count) titles")
		var changed = 0
		defer { if changed % 20 != 0 { onChange() } }
		for row in due {
			try Task.checkCancellation()
			try await lookup(row)
			changed += 1
			if changed % 20 == 0 { onChange() }
			try await Task.sleep(for: Self.pause)
		}
	}

	/// A row for every movie title and show in the libraries; automatic rows nothing uses go away.
	func sync() throws {
		let movieKey = "i.title || '|' || IFNULL(i.year, '')"
		let stale = """
			status IN (0, 1) AND NOT (
				(kind = 'movies' AND EXISTS (SELECT 1 FROM item i JOIN library l ON l.id = i.library_id
					WHERE l.type = 'movies' AND \(movieKey) = title_match.query))
				OR (kind = 'shows' AND EXISTS (SELECT 1 FROM show s JOIN library l ON l.id = s.library_id
					WHERE l.type = 'shows' AND s.name || '|' = title_match.query)))
			"""
		let gone = try store.writer.transaction {
			try store.writer.execute("""
				INSERT OR IGNORE INTO title_match (kind, query)
				SELECT DISTINCT 'movies', \(movieKey) FROM item i JOIN library l ON l.id = i.library_id
				WHERE l.type = 'movies' AND i.mime LIKE 'video/%';
				INSERT OR IGNORE INTO title_match (kind, query)
				SELECT 'shows', s.name || '|' FROM show s JOIN library l ON l.id = s.library_id WHERE l.type = 'shows'
				""")
			let ids = try store.writer.query("SELECT id FROM title_match WHERE poster = 1 AND \(stale)") { $0.int64(0) }
			try store.writer.execute("DELETE FROM title_match WHERE \(stale)")
			return ids
		}
		gone.forEach(removePoster)
		try refetchMissingPosters()
	}

	/// Matches whose poster file is gone are looked up again on the next pass; true when some were.
	@discardableResult
	func refetchMissingPosters() throws -> Bool {
		let missing = try store.reader.query("SELECT id FROM title_match WHERE poster = 1") { $0.int64(0) }.filter { id in
			!["tn", "sm"].allSatisfy { FileManager.default.fileExists(atPath: posterFile(id, $0).path) }
		}
		guard !missing.isEmpty else { return false }
		try store.writer.transaction {
			for id in missing { _ = try store.writer.run("UPDATE title_match SET poster = 0, checked_at = 0 WHERE id = ?", id) }
		}
		AppLog.library.info("\(missing.count) posters missing, downloading them again")
		onChange()
		return true
	}

	/// Matches one row automatically, or refreshes a match by hand. Only network failures are thrown.
	private func lookup(_ r: Row) async throws {
		await lock.wait()
		defer { lock.signal() }
		let (title, year) = Self.split(r.query)
		do {
			let d: MetaDetails
			switch (r.status, r.wikidata) {
			case let (.manual, qid?): d = try await client.details(r.kind, qid)
			default: d = try await match(r.kind, title, year)
			}
			try await save(r.id, status: r.status == .manual ? .manual : .auto, d)
		} catch MetaError.notFound {
			_ = try store.writer.run("UPDATE title_match SET checked_at = ? WHERE id = ?", Int64(Date().timeIntervalSince1970), r.id)
		}
	}

	func match(_ k: MetaKind, _ title: String, _ year: Int?) async throws -> MetaDetails {
		for q in TitleMatch.searchTitles(title) {
			if let best = TitleMatch.choose(q, year: year, try await client.search(k, q)) {
				return try await client.details(k, best.id)
			}
		}
		throw MetaError.notFound
	}

	private func save(_ id: Int64, status: MetaEntry.Status, _ d: MetaDetails) async throws {
		var poster = false
		if let url = d.posterURL {
			do {
				try await fetchPoster(id, url)
				poster = true
			} catch {
				AppLog.library.warning("poster \(url, privacy: .public) failed: \(error, privacy: .public)")
			}
		}
		if !poster { removePoster(id) }
		let text = { (s: String?) in s.flatMap { $0.isEmpty ? nil : $0 } }
		_ = try store.writer.run("""
			UPDATE title_match SET status = ?, wikidata = ?, title = ?, sort_title = ?, orig_title = ?, year = ?, overview = ?, genres = ?,
			director = ?, cast = ?, runtime = ?, poster = ?, checked_at = ? WHERE id = ?
			""", [status.rawValue, text(d.wikidata), text(d.title), text(d.title).map(Names.sortKey), text(d.origTitle), d.year, text(d.overview),
			      text(d.genres.joined(separator: ", ")), text(d.director), text(d.cast.joined(separator: ", ")), d.runtime, poster,
			      Int64(Date().timeIntervalSince1970), id])
	}

	// MARK: By hand

	func entries() throws -> [MetaEntry] {
		try store.reader.query("""
			SELECT id, kind, query, status, title, year, wikidata, poster, checked_at FROM title_match
			ORDER BY status = 0 AND checked_at > 0 DESC, kind, IFNULL(sort_title, query)
			""") { r in
			let (t, y) = Self.split(r.text(2))
			return MetaEntry(id: r.int64(0), isShow: r.text(1) == MetaKind.shows.rawValue, fileTitle: t, fileYear: y,
			                 status: MetaEntry.Status(rawValue: r.int(3)) ?? .pending, title: r.optText(4), year: r.optInt(5),
			                 wikidata: r.optText(6), poster: r.bool(7) ? posterFile(r.int64(0), "sm") : nil, checked: r.int64(8) > 0)
		}
	}

	private func kind(_ id: Int64) throws -> MetaKind {
		// The row may be missing, and its text may not be a kind: a double optional.
		// swiftlint:disable:next redundant_nil_coalescing
		guard let k = try store.reader.one("SELECT kind FROM title_match WHERE id = ?", id, map: { MetaKind(rawValue: $0.text(0)) }) ?? nil
		else { throw MetaError.notFound }
		return k
	}

	func search(_ id: Int64, _ query: String) async throws -> [MetaCandidate] {
		try await client.search(try kind(id), query)
	}

	/// Matches a title by hand to a Wikidata entity, or to nothing when qid is nil.
	func set(_ id: Int64, wikidata qid: String?) async throws {
		let k = try kind(id)
		if let qid, qid.wholeMatch(of: /Q\d+/) == nil { throw MetaError.notFound }
		await lock.wait()
		defer { lock.signal() }
		if let qid {
			try await save(id, status: .manual, try await client.details(k, qid))
		} else {
			try await save(id, status: .none, MetaDetails())
		}
		onChange()
	}

	/// Forgets a match so the next pass looks the title up again.
	func rematch(_ id: Int64) throws {
		_ = try store.writer.run("UPDATE title_match SET status = 0, checked_at = 0 WHERE id = ?", id)
		kick()
	}

	// MARK: Posters

	func posterFile(_ id: Int64, _ size: String) -> URL { dir.appending(path: "\(id)-\(size).jpg") }

	private func removePoster(_ id: Int64) {
		for size in ["tn", "sm"] { try? FileManager.default.removeItem(at: posterFile(id, size)) }
	}

	private func fetchPoster(_ id: Int64, _ url: URL) async throws {
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		let src = dir.appending(path: "\(id).download")
		defer { try? FileManager.default.removeItem(at: src) }
		try await client.download(url, to: src)
		for size in ["sm", "tn"] {
			// swiftlint:disable:next force_unwrapping
			guard Thumbnails.encode(from: src, RenditionSize.named(size)!, to: posterFile(id, size)) else {
				throw MetaError.http(0, "poster is not an image")
			}
		}
	}
}
