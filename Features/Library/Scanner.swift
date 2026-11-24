import Foundation
import Synchronization

/// A configured library with its row id in the index.
nonisolated struct IndexedLibrary: Sendable {
	let id: Int64
	let library: Library
	var type: LibraryType { library.type }
	var paths: [String] { library.paths }
}

/// What the file name (and later the file itself) says about an item.
nonisolated struct Described: Sendable {
	var title = ""
	var sortTitle = ""
	var year: Int?
	var show: String?
	var season: Int?
	var episode: Int?
	var episodeTitle: String?
	var taken: Date?
	var width: Int?
	var height: Int?
	var orientation: Int?
	var artist: String?
	var albumArtist: String?
	var album: String?
	var genre: String?
	var disc: Int?
	var track: Int?
	var hasArt = false
}

/// Keeps the index in sync with the library folders: a full scan on start and every 6 hours,
/// a rescan of a library a few seconds after FSEvents reports a change in it,
/// and every minute a cheap check of folder modification times (network volumes, missed events).
nonisolated final class LibraryScanner: BackgroundService {
	static let checkInterval = Duration.seconds(60)
	static let fullInterval: TimeInterval = 6 * 3600
	/// Files modified more recently may still be copying; their library is checked again on the next round.
	static let settleTime: TimeInterval = 120
	/// A long copy reports changes all the time; event-driven rescans are at least this far apart.
	static let minEventGap = Duration.seconds(10)

	let store: Store
	let libraries: [IndexedLibrary]
	let prober: Prober
	let onChange: @Sendable (UInt32) -> Void

	private struct State {
		var dirs: [Int64: [String: Date]] = [:] // library → folder → mtime at last scan
		var pending: Set<Int64> = []
		var changed = false // FSEvents reported a change since the last round
		var lastRound = ContinuousClock.now
		var scanning = false
		var missing: [Int64: [String]] = [:] // library → roots not reachable in the last scan
	}
	private let state = Mutex(State())

	init(store: Store, libraries: [IndexedLibrary], prober: Prober = Prober(), onChange: @escaping @Sendable (UInt32) -> Void) {
		self.store = store
		self.libraries = libraries
		self.prober = prober
		self.onChange = onChange
		if !prober.available { AppLog.library.warning("ffprobe not found, durations and music tags stay unknown") }
	}

	func run() async {
		let roots = libraries.flatMap { lib in lib.paths.map { (root: FolderWatcher.realPath($0), id: lib.id) } }
		let watcher = FolderWatcher(paths: roots.map(\.root), latency: 3) { [weak self] paths in
			self?.markChanged(FolderWatcher.libraries(for: paths, roots: roots))
		}
		defer { withExtendedLifetime(watcher) {} }
		do {
			self.scanAll(force: true)
			var lastFull = Date()
			while !Task.isCancelled {
				// Probing a large import takes minutes; it yields to the folder check every interval.
				if await !self.probePending(for: Self.checkInterval) {
					do { try await self.waitForChange(upTo: Self.checkInterval) } catch { return }
				}
				let full = Date().timeIntervalSince(lastFull) > Self.fullInterval
				if full { lastFull = Date() }
				self.scanAll(force: full)
			}
		}
	}

	func markChanged(_ ids: Set<Int64>) {
		guard !ids.isEmpty else { return }
		state.withLock {
			$0.pending.formUnion(ids)
			$0.changed = true
		}
	}

	var scanning: Bool { state.withLock { $0.scanning } }

	func missingRoots() -> [Int64: [String]] { state.withLock { $0.missing } }

	private var changeDue: Bool {
		state.withLock { $0.changed && ContinuousClock.now - $0.lastRound >= Self.minEventGap }
	}

	private func waitForChange(upTo timeout: Duration) async throws {
		let deadline = ContinuousClock.now + timeout
		while ContinuousClock.now < deadline, !changeDue {
			try await Task.sleep(for: .seconds(1))
		}
	}

	/// Scans libraries that changed (all with force) and bumps SystemUpdateID when the index changed.
	func scanAll(force: Bool) {
		state.withLock {
			$0.changed = false
			$0.lastRound = .now
			$0.scanning = true
		}
		defer { state.withLock { $0.scanning = false } }
		var changed = false
		for lib in libraries where force || needsScan(lib) {
			guard !Task.isCancelled else { return }
			let start = Date()
			do {
				let st = try scan(lib)
				if st.changed {
					changed = true
					AppLog.library.info("scanned \(lib.library.name, privacy: .public): +\(st.added) ~\(st.updated) -\(st.removed) in \(Int(Date().timeIntervalSince(start) * 1000)) ms")
				}
			} catch {
				AppLog.library.error("scan of \(lib.library.name, privacy: .public) failed: \(error, privacy: .public)")
			}
		}
		if changed, let id = try? store.bumpUpdateID() { onChange(id) }
	}

	private func needsScan(_ lib: IndexedLibrary) -> Bool {
		let (known, pending) = state.withLock { ($0.dirs[lib.id], $0.pending.contains(lib.id)) }
		guard let known, !pending else { return true }
		let fm = FileManager.default
		// A root that appeared (external drive mounted) or any folder whose mtime changed.
		if lib.paths.contains(where: { known[$0] == nil && fm.fileExists(atPath: $0) }) { return true }
		return known.contains { dir, mtime in
			(try? fm.attributesOfItem(atPath: dir)[.modificationDate] as? Date) != mtime
		}
	}

	struct Stats {
		var added = 0, updated = 0, removed = 0
		var changed: Bool { added + updated + removed > 0 }
	}

	struct Found {
		var root: String
		var relDir: String
		var path: String
		var format: MediaFormat
		var size: Int64
		var mtime: Int64
		var meta: Described?
		var subtitle: String?
	}

	struct Existing {
		var id: Int64
		var size: Int64
		var mtime: Int64
		var subtitle: String?
	}

	func scan(_ lib: IndexedLibrary) throws -> Stats {
		let known = try existing(lib.id, store.reader)
		var dirMtimes: [String: Date] = [:]
		var files: [Found] = []
		var srts: [String: [String]] = [:] // folder → .srt names
		var missingRoots: Set<String> = []
		var recent = false
		let cutoff = Date().addingTimeInterval(-Self.settleTime)
		let fm = FileManager.default

		for root in lib.paths {
			guard let rootAttrs = try? fm.attributesOfItem(atPath: root), rootAttrs[.type] as? FileAttributeType == .typeDirectory,
			      let walker = fm.enumerator(atPath: root) else {
				AppLog.library.warning("folder unavailable: \(root, privacy: .public)")
				missingRoots.insert(root)
				continue
			}
			dirMtimes[root] = rootAttrs[.modificationDate] as? Date
			while let rel = walker.nextObject() as? String {
				if Task.isCancelled { throw CancellationError() }
				let name = (rel as NSString).lastPathComponent
				let attrs = walker.fileAttributes ?? [:]
				let type = attrs[.type] as? FileAttributeType
				if name.hasPrefix(".") {
					if type == .typeDirectory { walker.skipDescendants() }
					continue
				}
				let path = root + "/" + rel
				let mtime = attrs[.modificationDate] as? Date ?? .distantPast
				if type == .typeDirectory {
					dirMtimes[path] = mtime
					continue
				}
				guard type == .typeRegular else { continue }
				let relDir = (rel as NSString).deletingLastPathComponent
				if lib.type.accepts(.video), name.lowercased().hasSuffix(".srt") {
					srts[(path as NSString).deletingLastPathComponent, default: []].append(name)
					continue
				}
				guard let format = MediaFormat.lookup(name), lib.type.accepts(format.kind) else { continue }
				if mtime > cutoff { recent = true }
				var f = Found(root: root, relDir: relDir, path: path, format: format,
				              size: (attrs[.size] as? NSNumber)?.int64Value ?? 0, mtime: Int64(mtime.timeIntervalSince1970))
				// Described only when new or changed, outside the write transaction.
				if let e = known[path], e.size == f.size, e.mtime == f.mtime {} else {
					f.meta = Self.describe(lib.type, path: path, rel: rel, mtime: mtime)
				}
				files.append(f)
			}
		}
		for i in files.indices {
			files[i].subtitle = Self.matchSubtitle(files[i].path, srts[(files[i].path as NSString).deletingLastPathComponent] ?? [])
		}
		let st = try reconcile(lib, files, missingRoots: missingRoots)
		state.withLock {
			$0.dirs[lib.id] = dirMtimes
			$0.missing[lib.id] = missingRoots.sorted()
			if recent { $0.pending.insert(lib.id) } else { $0.pending.remove(lib.id) }
		}
		return st
	}

	private func existing(_ libID: Int64, _ db: Database) throws -> [String: Existing] {
		let rows = try db.query("SELECT id, path, size, mtime, subtitle FROM item WHERE library_id = ?", libID) {
			($0.text(1), Existing(id: $0.int64(0), size: $0.int64(2), mtime: $0.int64(3), subtitle: $0.optText(4)))
		}
		return Dictionary(rows, uniquingKeysWith: { a, _ in a })
	}

	/// "<video>.srt" or "<video>.<lang>.srt", Czech preferred.
	static func matchSubtitle(_ videoPath: String, _ srts: [String]) -> String? {
		let base = Names.stripExt((videoPath as NSString).lastPathComponent).lowercased()
		var best: (name: String, score: Int)?
		for name in srts {
			let stem = Names.stripExt(name).lowercased()
			let score: Int
			if stem == base {
				score = 1
			} else if stem.hasPrefix(base + ".") {
				let lang = stem.dropFirst(base.count + 1)
				score = ["cs", "cz", "cze", "ces", "czech", "cesky", "česky"].contains(String(lang)) ? 0 : 2
			} else {
				continue
			}
			if score < best?.score ?? .max { best = (name, score) }
		}
		return best.map { ((videoPath as NSString).deletingLastPathComponent as NSString).appendingPathComponent($0.name) }
	}

	private func reconcile(_ lib: IndexedLibrary, _ files: [Found], missingRoots: Set<String>) throws -> Stats {
		let db = store.writer
		return try db.transaction {
			var st = Stats()
			var items = try existing(lib.id, db)
			let firstScan = items.isEmpty

			struct DirKey: Hashable { let root: String, rel: String }
			var dirs: [DirKey: Int64] = [:]
			var dirRoots: [Int64: String] = [:]
			for (id, root, rel) in try db.query("SELECT id, root, rel FROM dir WHERE library_id = ?", lib.id, map: { ($0.int64(0), $0.text(1), $0.text(2)) }) {
				dirs[DirKey(root: root, rel: rel)] = id
				dirRoots[id] = root
			}
			var used: Set<Int64> = []

			func ensureDir(_ root: String, _ rel: String) throws -> Int64 {
				let parentRel = rel.isEmpty ? nil : (rel as NSString).deletingLastPathComponent
				if let id = dirs[DirKey(root: root, rel: rel)] {
					// Ancestors must stay too: deleting an unused parent cascades to this folder.
					if used.insert(id).inserted, let parentRel { _ = try ensureDir(root, parentRel) }
					return id
				}
				let parent = try parentRel.map { try ensureDir(root, $0) }
				let name = ((rel.isEmpty ? root : rel) as NSString).lastPathComponent.precomposedStringWithCanonicalMapping
				let id = try db.one("INSERT INTO dir (library_id, root, rel, parent_id, name, sort_name) VALUES (?, ?, ?, ?, ?, ?) RETURNING id",
				                    // swiftlint:disable:next force_unwrapping
				                    lib.id, root, rel, parent, name, Names.sortKey(name)) { $0.int64(0) }!
				dirs[DirKey(root: root, rel: rel)] = id
				used.insert(id)
				return id
			}

			var entities = Entities(db: db, libID: lib.id)
			let now = Int64(Date().timeIntervalSince1970)
			for f in files {
				let dirID = try ensureDir(f.root, f.relDir)
				let old = items.removeValue(forKey: f.path)
				guard let m = f.meta else {
					// Subtitles can appear or disappear without the video changing.
					if let old, old.subtitle != f.subtitle {
						try db.run("UPDATE item SET subtitle = ? WHERE id = ?", f.subtitle, old.id)
						st.updated += 1
					}
					continue
				}
				let ref = try entities.resolve(m)
				let cols: [any SQLBindable] = [dirID, f.size, f.mtime, m.title, Names.sortKey(m.sortTitle), m.year, ref.show,
				                               m.season, m.episode, m.episodeTitle, m.taken.map { Int64($0.timeIntervalSince1970) },
				                               m.width, m.height, m.orientation, m.artist, ref.artist, ref.album, ref.genre,
				                               m.disc, m.track, m.hasArt, f.subtitle]
				if let old {
					try db.run("""
						UPDATE item SET dir_id = ?, size = ?, mtime = ?, title = ?, sort_title = ?, year = ?, show_id = ?, season = ?,
						episode = ?, episode_title = ?, taken_at = ?, width = ?, height = ?, orientation = ?, artist = ?, artist_id = ?,
						album_id = ?, genre_id = ?, disc = ?, track = ?, has_art = ?, subtitle = ?, probed = 0 WHERE id = ?
						""", cols + [old.id])
					st.updated += 1
				} else {
					// On the very first import file times make "recently added" reflect real history.
					try db.run("""
						INSERT INTO item (dir_id, size, mtime, title, sort_title, year, show_id, season, episode, episode_title,
						taken_at, width, height, orientation, artist, artist_id, album_id, genre_id, disc, track, has_art, subtitle,
						library_id, path, name, mime, added_at)
						VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
						""", cols + [lib.id, f.path, (f.path as NSString).lastPathComponent, f.format.mime, firstScan ? f.mtime : now])
					st.added += 1
				}
			}

			// Items of an unavailable root (drive not mounted) are kept until it comes back.
			let isMissing = { (path: String) in missingRoots.contains { path.hasPrefix($0 + "/") } }
			for (path, e) in items where !isMissing(path) {
				try db.run("DELETE FROM item WHERE id = ?", e.id)
				st.removed += 1
			}
			for (_, id) in dirs where !used.contains(id) && !missingRoots.contains(dirRoots[id] ?? "") {
				try db.run("DELETE FROM dir WHERE id = ?", id)
			}
			try pruneEntities([lib.id])
			return st
		}
	}

	private struct ProbeJob: Sendable {
		var id: Int64
		var path: String
		var rel: String
		var libID: Int64
		var music: Bool
	}

	/// Fills duration, codecs and music tags of new or changed items, two files at a time.
	/// Returns true when the time budget ran out (or a folder change is due) with items still pending.
	func probePending(for budget: Duration) async -> Bool {
		guard prober.available else { return false }
		let deadline = ContinuousClock.now + budget
		var touched: Set<Int64> = []
		defer {
			if !touched.isEmpty {
				do {
					try store.writer.transaction { try pruneEntities(touched) }
					onChange(try store.bumpUpdateID())
				} catch {
					AppLog.library.error("probe finish failed: \(error, privacy: .public)")
				}
			}
		}
		while !Task.isCancelled, ContinuousClock.now < deadline, !changeDue {
			let jobs: [ProbeJob]
			do {
				jobs = try store.reader.query("""
					SELECT i.id, i.path, d.root, i.library_id, l.type FROM item i
					JOIN dir d ON d.id = i.dir_id JOIN library l ON l.id = i.library_id
					WHERE i.probed = 0 AND (i.mime LIKE 'video/%' OR i.mime LIKE 'audio/%') LIMIT 32
					""") { r in
					let path = r.text(1), root = r.text(2)
					return ProbeJob(id: r.int64(0), path: path, rel: String(path.dropFirst(root.count + 1)), libID: r.int64(3),
					                music: r.text(4) == LibraryType.music.rawValue)
				}
			} catch {
				AppLog.library.error("probe query failed: \(error, privacy: .public)")
				return false
			}
			if jobs.isEmpty { return false }
			let results = await withTaskGroup(of: (ProbeJob, ProbeInfo?).self) { group in
				var out: [(ProbeJob, ProbeInfo?)] = []
				for (i, job) in jobs.enumerated() {
					if i >= 2, let r = await group.next() { out.append(r) }
					group.addTask {
						do { return (job, try await self.prober.probe(job.path)) } catch {
							AppLog.library.debug("probe of \(job.path, privacy: .private) failed: \(error, privacy: .public)")
							return (job, nil)
						}
					}
				}
				for await r in group { out.append(r) }
				return out
			}
			if Task.isCancelled { return false }
			do {
				try save(results)
				touched.formUnion(results.map(\.0.libID))
			} catch {
				AppLog.library.error("probe save failed: \(error, privacy: .public)")
				return false
			}
		}
		return !Task.isCancelled
	}

	private func save(_ results: [(ProbeJob, ProbeInfo?)]) throws {
		let db = store.writer
		try db.transaction {
			var entities: [Int64: Entities] = [:]
			for (job, info) in results {
				// Failed probes (2) are retried only when the file changes.
				guard let p = info else {
					try db.run("UPDATE item SET probed = 2 WHERE id = ?", job.id)
					continue
				}
				try db.run("""
					UPDATE item SET probed = 1, duration_ms = ?, bitrate = ?, container = ?, video_codec = ?, audio_codec = ?,
					width = COALESCE(?, width), height = COALESCE(?, height), pix_fmt = ?, audio_channels = ? WHERE id = ?
					""", p.durationMs, p.bitrate, p.container, p.videoCodec, p.audioCodec, p.width, p.height, p.pixFmt, p.channels, job.id)
				guard job.music else { continue }
				let m = AudioMeta.merge(AudioMeta.fromLayout(rel: job.rel.precomposedStringWithCanonicalMapping, path: job.path), p)
				var e = entities[job.libID] ?? Entities(db: db, libID: job.libID)
				let ref = try e.resolve(m)
				entities[job.libID] = e
				try db.run("""
					UPDATE item SET title = ?, sort_title = ?, year = ?, artist = ?, artist_id = ?, album_id = ?, genre_id = ?,
					disc = ?, track = ?, has_art = ? WHERE id = ?
					""", m.title, Names.sortKey(m.sortTitle), m.year, m.artist, ref.artist, ref.album, ref.genre, m.disc, m.track, m.hasArt, job.id)
			}
		}
	}

	/// Drops shows, albums, artists and genres no item refers to any more.
	private func pruneEntities(_ libIDs: Set<Int64>) throws {
		for lib in libIDs {
			for table in ["show", "album", "artist", "genre"] {
				try store.writer.run("DELETE FROM \(table) WHERE library_id = ? AND id NOT IN (SELECT \(table)_id FROM item WHERE \(table)_id IS NOT NULL)", lib)
			}
		}
	}

	/// Creates shows, artists, albums and genres on demand within a scan transaction.
	private struct Entities {
		let db: Database
		let libID: Int64
		var cache: [String: Int64] = [:]

		struct Refs { var show, artist, album, genre: Int64? }

		mutating func get(_ key: String, _ sql: String, _ args: any SQLBindable...) throws -> Int64 {
			if let id = cache[key] { return id }
			// swiftlint:disable:next force_unwrapping
			let id = try db.query(sql, args) { $0.int64(0) }.first!
			cache[key] = id
			return id
		}

		mutating func resolve(_ m: Described) throws -> Refs {
			var r = Refs()
			let upsert = "ON CONFLICT (library_id, name) DO UPDATE SET sort_name = excluded.sort_name RETURNING id"
			if let s = m.show {
				r.show = try get("s\0" + s, "INSERT INTO show (library_id, name, sort_name) VALUES (?, ?, ?) " + upsert, libID, s, Names.sortKey(s))
			}
			if let a = m.albumArtist ?? (m.album != nil ? "Neznámý interpret" : nil) {
				r.artist = try get("a\0" + a, "INSERT INTO artist (library_id, name, sort_name) VALUES (?, ?, ?) " + upsert, libID, a, Names.sortKey(a))
			}
			if let al = m.album, let artist = r.artist {
				r.album = try get("b\0\(artist)\0" + al, """
					INSERT INTO album (library_id, artist_id, title, sort_title, year) VALUES (?, ?, ?, ?, ?)
					ON CONFLICT (library_id, artist_id, title) DO UPDATE SET year = COALESCE(excluded.year, album.year) RETURNING id
					""", libID, artist, al, Names.sortKey(al), m.year)
			}
			if let g = m.genre {
				r.genre = try get("g\0" + g, "INSERT INTO genre (library_id, name, sort_name) VALUES (?, ?, ?) " + upsert, libID, g, Names.sortKey(g))
			}
			return r
		}
	}

	/// File names from macOS are often decomposed; TVs render composed (NFC) text more reliably.
	static func describe(_ type: LibraryType, path: String, rel: String, mtime: Date) -> Described {
		let rel = rel.precomposedStringWithCanonicalMapping
		let name = (rel as NSString).lastPathComponent
		let stem = Names.stripExt(name)
		switch type {
		case .movies:
			let (t, y) = Names.movie(name)
			return Described(title: t, sortTitle: t, year: y > 0 ? y : nil)
		case .shows:
			if let ep = Names.episode(rel) {
				return Described(title: ep.show, sortTitle: "\(ep.show) \(ep.season) \(ep.episode)", show: ep.show,
				                 season: ep.season, episode: ep.episode, episodeTitle: ep.title.isEmpty ? nil : ep.title)
			}
		case .photos:
			var d = Described(title: stem, sortTitle: stem, taken: mtime, hasArt: true)
			if let p = PhotoInfo.read(path) {
				(d.width, d.height, d.orientation) = (p.width, p.height, p.orientation)
				if let t = p.taken { d.taken = t }
			}
			return d
		case .music:
			return AudioMeta.fromLayout(rel: rel, path: path)
		case .videos:
			break
		}
		return Described(title: stem, sortTitle: stem)
	}
}
