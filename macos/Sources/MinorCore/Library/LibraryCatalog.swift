import Foundation

/// One entry of the ContentDirectory tree.
struct CatalogObject: Sendable, Equatable {
	var id: String
	var parentID: String
	var title: String
	var isContainer: Bool
	var childCount: Int?
	var upnpClass: String?
	var path: String?
	var format: MediaFormat?
	var size: Int64 = 0
	var modified: Date?
	var year: Int?
	var taken: Date?
	var durationMs: Int?
	var width: Int?
	var height: Int?
	var artist: String?
	var album: String?
	var genre: String?
	var track: Int?
	var subtitle: String?
	var orientation: Int?
	// From ffprobe, for the transcoding decision.
	var container: String?
	var videoCodec: String?
	var audioCodec: String?
	var pixFmt: String?
	var channels: Int?
	/// Item whose thumbnail is the album art (/thumb/<id>/tn.jpg).
	var artItem: Int64?
}

/// Browses the index. Object IDs never contain paths:
///
///	"0"             root
///	"L<id>"         library, "L<id>/<view>" its views (all, recent, years, y<year>, folders, shows, dates, py<year>, pm<year>-<month>, artists, albums, genres)
///	"D<id>"         folder
///	"S<id>"         show, "S<id>/<season>" season
///	"A<id>" "B<id>" "G<id>"  artist, album, genre
///	"I<id>"         media item, served at /media/<id>.<ext>
struct LibraryCatalog: Sendable {
	let db: Database
	let libraries: [IndexedLibrary]
	/// Videos get a frame as thumbnail (needs ffmpeg).
	var videoArt = false
	static let recentLimit = 50

	static let classAlbum = "object.container.album.musicAlbum"
	static let classArtist = "object.container.person.musicArtist"
	static let classGenre = "object.container.genre.musicGenre"
	static let classPhotoAlbum = "object.container.album.photoAlbum"

	static func views(_ t: LibraryType) -> [(key: String, title: String)] {
		switch t {
		case .movies: [("all", "Všechny filmy"), ("recent", "Naposledy přidané"), ("years", "Podle roku"), ("folders", "Složky")]
		case .shows: [("shows", "Seriály"), ("recent", "Naposledy přidané"), ("folders", "Složky")]
		case .videos: [("folders", "Složky"), ("recent", "Naposledy přidané")]
		case .photos: [("dates", "Podle data"), ("folders", "Složky")]
		case .music: [("artists", "Interpreti"), ("albums", "Alba"), ("genres", "Žánry"), ("folders", "Složky")]
		}
	}

	func metadata(_ id: String) throws(UPnPError) -> CatalogObject {
		try mapErrors { try objectMetadata(id) }
	}

	func children(_ id: String, start: Int, count: Int) throws(UPnPError) -> (objects: [CatalogObject], total: Int) {
		try mapErrors {
			do { return try list(id, start, count) } catch is IsItem { throw UPnPError.noSuchObject }
		}
	}

	/// The item behind a media URL path such as "123.mkv".
	func media(_ name: Substring) -> CatalogObject? {
		guard let n = Int64(name.prefix { $0 != "." }) else { return nil }
		return try? items("", .folder, "i.id = ?", "i.id", 0, 1, [n]).first
	}

	// MARK: -

	private struct IsItem: Error {}

	private func mapErrors<T>(_ body: () throws -> T) throws(UPnPError) -> T {
		do {
			return try body()
		} catch let e as UPnPError {
			throw e
		} catch {
			Log.library.error("browse failed: \(error, privacy: .public)")
			throw .actionFailed
		}
	}

	private func container(_ id: String, _ parent: String, _ title: String, _ count: Int?, _ cls: String? = nil) -> CatalogObject {
		CatalogObject(id: id, parentID: parent, title: title, isContainer: true, childCount: count, upnpClass: cls)
	}

	private func page(_ all: [CatalogObject], _ start: Int, _ count: Int) -> ([CatalogObject], Int) {
		let from = min(start, all.count)
		let to = count == 0 ? all.count : min(from + count, all.count)
		return (Array(all[from..<to]), all.count)
	}

	private func libID(_ l: IndexedLibrary) -> String { "L\(l.id)" }

	private func objectMetadata(_ id: String) throws -> CatalogObject {
		if id == "0" { return container("0", "-1", "MinorDLNA", libraries.count) }
		var total: Int?
		do { total = try list(id, 0, 1).1 } catch is IsItem {}
		switch id.first {
		case "L":
			let (lib, v) = try parseLib(id)
			if v.isEmpty { return container(id, "0", lib.library.name, total) }
			var parent = libID(lib)
			var title = Self.views(lib.type).first { $0.key == v }?.title ?? v
			if v.hasPrefix("py") {
				(parent, title) = (libID(lib) + "/dates", String(v.dropFirst(2)))
			} else if v.hasPrefix("pm") {
				(parent, title) = (libID(lib) + "/py" + v.dropFirst(2).prefix(4), Self.monthTitle(v.dropFirst(2)))
			} else if v.hasPrefix("y") {
				(parent, title) = (libID(lib) + "/years", String(v.dropFirst()))
			}
			return container(id, parent, title, total, v.hasPrefix("pm") ? Self.classPhotoAlbum : nil)
		case "D":
			let d = try dir(id)
			return container(id, d.parentID, d.name, total)
		case "S":
			let (show, season) = try parseShow(id)
			guard let (name, lib) = try db.one("SELECT name, library_id FROM show WHERE id = ?", show, map: { ($0.text(0), $0.int64(1)) }) else {
				throw UPnPError.noSuchObject
			}
			if let season { return container(id, "S\(show)", Self.seasonTitle(season), total) }
			return container(id, "L\(lib)/shows", name, total)
		case "A", "B", "G":
			return try musicMetadata(id, total)
		case "I":
			guard let o = media(id.dropFirst()) else { throw UPnPError.noSuchObject }
			return o
		default:
			throw UPnPError.noSuchObject
		}
	}

	private func list(_ id: String, _ start: Int, _ count: Int) throws -> ([CatalogObject], Int) {
		if id == "0" { return page(libraries.map { container(libID($0), "0", $0.library.name, nil) }, start, count) }
		switch id.first {
		case "L":
			let (lib, v) = try parseLib(id)
			return try libChildren(lib, id, v, start, count)
		case "D":
			return try dirChildren(id, try dir(id).id, start, count)
		case "S":
			let (show, season) = try parseShow(id)
			if let season {
				return try itemPage(id, .season, "i.show_id = ? AND i.season = ?", "i.episode, i.sort_title", start, count, [show, season])
			}
			return try groups(id, "SELECT COALESCE(season, 0), COUNT(*) FROM item WHERE show_id = ? GROUP BY 1 ORDER BY 1", [show], start, count) {
				("\(id)/\($0)", Self.seasonTitle(Int($0)))
			}
		case "A", "B", "G":
			return try musicChildren(id, start, count)
		case "I":
			throw IsItem()
		default:
			throw UPnPError.noSuchObject
		}
	}

	private func libChildren(_ lib: IndexedLibrary, _ id: String, _ v: String, _ start: Int, _ count: Int) throws -> ([CatalogObject], Int) {
		switch v {
		case "":
			return page(Self.views(lib.type).map { container("\(id)/\($0.key)", id, $0.title, nil) }, start, count)
		case "folders":
			return try folders(lib, id, start, count)
		case "all":
			return try itemPage(id, .movie, "i.library_id = ?", "i.sort_title", start, count, [lib.id])
		case "recent":
			guard start < Self.recentLimit else { return ([], Self.recentLimit) }
			let n = count == 0 ? Self.recentLimit - start : min(count, Self.recentLimit - start)
			let (objs, total) = try itemPage(id, .recent, "i.library_id = ?", "i.added_at DESC, i.id DESC", start, n, [lib.id])
			return (objs, min(total, Self.recentLimit))
		case "years":
			return try groups(id, "SELECT year, COUNT(*) FROM item WHERE library_id = ? AND year IS NOT NULL GROUP BY year ORDER BY year DESC",
			                  [lib.id], start, count) { ("\(libID(lib))/y\($0)", String($0)) }
		case "shows":
			return try named(id, "S", """
				SELECT s.id, s.name, COUNT(i.id) FROM show s JOIN item i ON i.show_id = s.id
				WHERE s.library_id = ? GROUP BY s.id ORDER BY s.sort_name
				""", [lib.id], start, count)
		case "dates":
			return try groups(id, """
				SELECT CAST(strftime('%Y', taken_at, 'unixepoch', 'localtime') AS INTEGER) y, COUNT(*)
				FROM item WHERE library_id = ? AND taken_at IS NOT NULL GROUP BY y ORDER BY y DESC
				""", [lib.id], start, count) { ("\(libID(lib))/py\($0)", String($0)) }
		case "artists":
			return try named(id, "A", """
				SELECT ar.id, ar.name, COUNT(DISTINCT i.album_id) FROM artist ar JOIN item i ON i.artist_id = ar.id
				WHERE ar.library_id = ? GROUP BY ar.id ORDER BY ar.sort_name
				""", [lib.id], start, count, Self.classArtist)
		case "genres":
			return try named(id, "G", """
				SELECT g.id, g.name, COUNT(DISTINCT i.album_id) FROM genre g JOIN item i ON i.genre_id = g.id
				WHERE g.library_id = ? GROUP BY g.id ORDER BY g.sort_name
				""", [lib.id], start, count, Self.classGenre)
		case "albums":
			return try albums(id, "al.library_id = ?", "al.sort_title", [lib.id], start, count)
		default:
			if v.hasPrefix("y"), let year = Int(v.dropFirst()) {
				return try itemPage(id, .movie, "i.library_id = ? AND i.year = ?", "i.sort_title", start, count, [lib.id, year])
			}
			if v.hasPrefix("py"), let y = Int(v.dropFirst(2)) {
				let (from, to) = (Self.localDate(y, 1), Self.localDate(y + 1, 1))
				return try groups(id, """
					SELECT CAST(strftime('%m', taken_at, 'unixepoch', 'localtime') AS INTEGER) m, COUNT(*)
					FROM item WHERE library_id = ? AND taken_at >= ? AND taken_at < ? GROUP BY m ORDER BY m
					""", [lib.id, from, to], start, count, Self.classPhotoAlbum) {
					let ym = String(format: "%04d-%02d", y, $0)
					return ("\(libID(lib))/pm\(ym)", Self.monthTitle(Substring(ym)))
				}
			}
			if v.hasPrefix("pm"), let (y, m) = Self.parseYM(v.dropFirst(2)) {
				let from = Self.localDate(y, m), to = m == 12 ? Self.localDate(y + 1, 1) : Self.localDate(y, m + 1)
				return try itemPage(id, .folder, "i.library_id = ? AND i.taken_at >= ? AND i.taken_at < ?", "i.taken_at, i.sort_title",
				                    start, count, [lib.id, from, to])
			}
			throw UPnPError.noSuchObject
		}
	}

	/// The single root's contents, or one container per configured folder.
	private func folders(_ lib: IndexedLibrary, _ id: String, _ start: Int, _ count: Int) throws -> ([CatalogObject], Int) {
		if lib.paths.count == 1 {
			guard let root = try db.one("SELECT id FROM dir WHERE library_id = ? AND root = ? AND rel = ''", lib.id, lib.paths[0], map: { $0.int64(0) })
			else { return ([], 0) }
			return try dirChildren(id, root, start, count)
		}
		let roots = try db.query("SELECT id, name, root FROM dir WHERE library_id = ? AND parent_id IS NULL", lib.id) {
			(container("D\($0.int64(0))", id, $0.text(1), nil), $0.text(2))
		}
		let order = { (root: String) in lib.paths.firstIndex(of: root) ?? .max }
		return page(roots.sorted { order($0.1) < order($1.1) }.map(\.0), start, count)
	}

	private func dirChildren(_ id: String, _ dirID: Int64, _ start: Int, _ count: Int) throws -> ([CatalogObject], Int) {
		let nDirs = try db.one("SELECT COUNT(*) FROM dir WHERE parent_id = ?", dirID) { $0.int(0) } ?? 0
		var out: [CatalogObject] = []
		if start < nDirs {
			let limit = count > 0 ? min(nDirs - start, count) : nDirs - start
			out = try db.query("SELECT id, name FROM dir WHERE parent_id = ? ORDER BY sort_name LIMIT ? OFFSET ?", dirID, limit, start) {
				container("D\($0.int64(0))", id, $0.text(1), nil)
			}
		}
		let itemCount = count > 0 ? count - out.count : 0
		if count > 0, itemCount == 0 { // page filled by folders; still need the total
			return (out, nDirs + (try db.one("SELECT COUNT(*) FROM item WHERE dir_id = ?", dirID) { $0.int(0) } ?? 0))
		}
		let (items, nItems) = try itemPage(id, .folder, "i.dir_id = ?", "i.sort_title", max(start - nDirs, 0), itemCount, [dirID])
		return (out + items, nDirs + nItems)
	}

	// MARK: Music

	private func albums(_ parent: String, _ filter: String, _ order: String, _ args: [any SQLBindable], _ start: Int, _ count: Int)
		throws -> ([CatalogObject], Int)
	{
		let all = try db.query("""
			SELECT al.id, al.title, ar.name, COUNT(i.id), MIN(CASE WHEN i.has_art THEN i.id END) FROM album al
			JOIN artist ar ON ar.id = al.artist_id JOIN item i ON i.album_id = al.id WHERE \(filter) GROUP BY al.id ORDER BY \(order)
			""", args) { r in
			var o = container("B\(r.int64(0))", parent, r.text(1), r.int(3), Self.classAlbum)
			o.artist = r.text(2)
			o.artItem = r.isNull(4) ? nil : r.int64(4)
			return o
		}
		return page(all, start, count)
	}

	private func musicChildren(_ id: String, _ start: Int, _ count: Int) throws -> ([CatalogObject], Int) {
		guard let n = Int64(id.dropFirst()) else { throw UPnPError.noSuchObject }
		_ = try musicMetadata(id, nil)
		switch id.first {
		case "A": return try albums(id, "al.artist_id = ?", "al.year, al.sort_title", [n], start, count)
		case "G": return try albums(id, "al.id IN (SELECT album_id FROM item WHERE genre_id = ?)", "al.sort_title", [n], start, count)
		default: return try itemPage(id, .folder, "i.album_id = ?", "COALESCE(i.disc, 1), COALESCE(i.track, 0), i.sort_title", start, count, [n])
		}
	}

	private func musicMetadata(_ id: String, _ total: Int?) throws -> CatalogObject {
		guard let n = Int64(id.dropFirst()) else { throw UPnPError.noSuchObject }
		switch id.first {
		case "A", "G":
			let table = id.first == "A" ? "artist" : "genre"
			guard let (name, lib) = try db.one("SELECT name, library_id FROM \(table) WHERE id = ?", n, map: { ($0.text(0), $0.int64(1)) }) else {
				throw UPnPError.noSuchObject
			}
			return container(id, "L\(lib)/\(table)s", name, total, id.first == "A" ? Self.classArtist : Self.classGenre)
		default:
			guard var o = try albums("", "al.id = ?", "al.id", [n], 0, 1).0.first,
			      let lib = try db.one("SELECT library_id FROM album WHERE id = ?", n, map: { $0.int64(0) }) else { throw UPnPError.noSuchObject }
			o.parentID = "L\(lib)/albums"
			if let total { o.childCount = total }
			return o
		}
	}

	// MARK: Items

	private enum TitleContext { case folder, movie, season, recent }

	private func groups(_ parent: String, _ sql: String, _ args: [any SQLBindable], _ start: Int, _ count: Int, _ cls: String? = nil,
	                    _ make: (Int64) -> (String, String)) throws -> ([CatalogObject], Int)
	{
		let all = try db.query(sql, args) { r in
			let (id, title) = make(r.int64(0))
			return container(id, parent, title, r.int(1), cls)
		}
		return page(all, start, count)
	}

	private func named(_ parent: String, _ prefix: String, _ sql: String, _ args: [any SQLBindable], _ start: Int, _ count: Int,
	                   _ cls: String? = nil) throws -> ([CatalogObject], Int)
	{
		page(try db.query(sql, args) { container("\(prefix)\($0.int64(0))", parent, $0.text(1), $0.int(2), cls) }, start, count)
	}

	private func itemPage(_ parent: String, _ tc: TitleContext, _ filter: String, _ order: String, _ start: Int, _ count: Int,
	                      _ args: [any SQLBindable]) throws -> ([CatalogObject], Int)
	{
		let total = try db.query("SELECT COUNT(*) FROM item i WHERE \(filter)", args) { $0.int(0) }.first ?? 0
		return (try items(parent, tc, filter, order, start, count > 0 ? count : -1, args), total)
	}

	private func items(_ parent: String, _ tc: TitleContext, _ filter: String, _ order: String, _ start: Int, _ limit: Int,
	                   _ args: [any SQLBindable]) throws -> [CatalogObject]
	{
		try db.query("""
			SELECT i.id, i.library_id, i.dir_id, i.path, i.name, i.size, i.mtime, i.title, i.year, i.season, i.episode,
			i.episode_title, i.duration_ms, i.width, i.height, s.name, i.taken_at, i.artist, al.title, g.name, i.track, i.subtitle,
			i.orientation, i.has_art, i.container, i.video_codec, i.audio_codec, i.pix_fmt, i.audio_channels
			FROM item i LEFT JOIN show s ON s.id = i.show_id LEFT JOIN album al ON al.id = i.album_id LEFT JOIN genre g ON g.id = i.genre_id
			WHERE \(filter) ORDER BY \(order) LIMIT ? OFFSET ?
			""", args + [limit, start]) { r in
			let id = r.int64(0), name = r.text(4)
			var o = CatalogObject(id: "I\(id)", parentID: parent.isEmpty ? "D\(r.int64(2))" : parent, title: r.text(7), isContainer: false)
			o.path = r.text(3)
			o.format = MediaFormat.lookup(name)
			o.size = r.int64(5)
			o.modified = Date(timeIntervalSince1970: TimeInterval(r.int64(6)))
			o.year = r.optInt(8)
			o.durationMs = r.optInt(12)
			o.width = r.optInt(13)
			o.height = r.optInt(14)
			o.taken = r.optInt(16).map { Date(timeIntervalSince1970: TimeInterval($0)) }
			o.artist = r.optText(17)
			o.album = r.optText(18)
			o.genre = r.optText(19)
			o.track = r.optInt(20)
			o.subtitle = r.optText(21)
			o.orientation = r.optInt(22)
			o.container = r.optText(24)
			o.videoCodec = r.optText(25)
			o.audioCodec = r.optText(26)
			o.pixFmt = r.optText(27)
			o.channels = r.optInt(28)
			if r.bool(23) || (videoArt && o.format?.kind == .video) { o.artItem = id }
			if let lib = libraries.first(where: { $0.id == r.int64(1) }) {
				o.title = Self.displayTitle(lib.type, tc, o.title, year: o.year, show: r.optText(15), season: r.optInt(9) ?? 0,
				                            episode: r.optInt(10) ?? 0, episodeTitle: r.optText(11))
			}
			return o
		}
	}

	private static func displayTitle(_ t: LibraryType, _ tc: TitleContext, _ title: String, year: Int?, show: String?,
	                                 season: Int, episode: Int, episodeTitle: String?) -> String
	{
		if t == .movies, let year { return "\(title) (\(year))" }
		guard t == .shows, let show else { return title }
		var code = String(format: "S%02dE%02d", season, episode)
		switch tc {
		case .season: code = String(format: "%02d.", episode)
		case .recent, .folder: code = "\(show) \(code)"
		case .movie: break
		}
		return episodeTitle.map { "\(code) \($0)" } ?? code
	}

	// MARK: IDs

	private func parseLib(_ id: String) throws -> (IndexedLibrary, String) {
		let parts = id.dropFirst().split(separator: "/", maxSplits: 1)
		guard let n = parts.first.flatMap({ Int64($0) }), let lib = libraries.first(where: { $0.id == n }) else { throw UPnPError.noSuchObject }
		return (lib, parts.count > 1 ? String(parts[1]) : "")
	}

	private func parseShow(_ id: String) throws -> (Int64, Int?) {
		let parts = id.dropFirst().split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
		guard let show = Int64(parts[0]) else { throw UPnPError.noSuchObject }
		if parts.count == 1 { return (show, nil) }
		guard let season = Int(parts[1]) else { throw UPnPError.noSuchObject }
		return (show, season)
	}

	private func dir(_ id: String) throws -> (id: Int64, name: String, parentID: String) {
		guard let n = Int64(id.dropFirst()),
		      let (libID, name, parent, parentRel) = try db.one("""
		      	SELECT d.library_id, d.name, d.parent_id, p.rel FROM dir d LEFT JOIN dir p ON p.id = d.parent_id WHERE d.id = ?
		      	""", n, map: { ($0.int64(0), $0.text(1), $0.optInt(2), $0.optText(3)) }),
		      let lib = libraries.first(where: { $0.id == libID }) else { throw UPnPError.noSuchObject }
		// With one folder its root is the "folders" view itself, so its children point there.
		let folders = "\(self.libID(lib))/folders"
		guard let parent, !(lib.paths.count == 1 && parentRel == "") else { return (n, name, folders) }
		return (n, name, "D\(parent)")
	}

	// MARK: Dates

	private static let months = ["Leden", "Únor", "Březen", "Duben", "Květen", "Červen", "Červenec", "Srpen", "Září", "Říjen", "Listopad", "Prosinec"]

	static func seasonTitle(_ n: Int) -> String { n == 0 ? "Speciály" : "Série \(n)" }

	/// "2023-05" → "Květen 2023".
	static func monthTitle(_ ym: Substring) -> String {
		guard let (y, m) = parseYM(ym) else { return String(ym) }
		return "\(months[m - 1]) \(y)"
	}

	static func parseYM(_ ym: Substring) -> (Int, Int)? {
		let p = ym.split(separator: "-")
		guard p.count == 2, let y = Int(p[0]), let m = Int(p[1]), (1...12).contains(m) else { return nil }
		return (y, m)
	}

	/// Unix time of local midnight on the first of a month, so the taken_at index can be used.
	private static func localDate(_ y: Int, _ m: Int) -> Int64 {
		Int64(Calendar.current.date(from: DateComponents(year: y, month: m, day: 1))?.timeIntervalSince1970 ?? 0)
	}
}

extension LibraryType {
	func accepts(_ kind: MediaKind) -> Bool {
		switch self {
		case .movies, .shows, .videos: kind == .video
		case .photos: kind == .image
		case .music: kind == .audio
		}
	}
}
