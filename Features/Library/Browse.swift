import Foundation

/// A library entry for the app and the web: a folder to open or an item to play.
nonisolated struct BrowseEntry: Sendable, Equatable, Identifiable, Encodable {
	enum Kind: String, Sendable, Encodable {
		case folder, video, audio, image
	}

	var id: String
	var title: String
	var kind: Kind
	var childCount: Int?
	var year: Int?
	var durationMs: Int?
	var positionMs: Int
	var watched: Bool
	var overview: String?
	/// Small image on this server: /poster/… or /thumb/….
	var artPath: String?

	var playable: Bool { kind == .video || kind == .audio }

	init(_ o: CatalogObject) {
		id = o.id
		title = o.title
		kind = switch o.format?.kind {
		case _ where o.isContainer: .folder
		case .audio: .audio
		case .image: .image
		default: .video
		}
		childCount = o.childCount
		year = o.year
		durationMs = o.durationMs
		positionMs = o.positionMs
		watched = o.watched
		overview = o.overview
		let photo = kind == .image ? Int64(o.id.dropFirst()) : nil
		artPath = o.poster.map { DIDL.posterPath($0, "tn") } ?? (o.artItem ?? photo).map { DIDL.thumbPath($0, "tn") }
	}
}

nonisolated struct BrowsePage: Sendable, Equatable, Encodable {
	var id: String
	var title: String
	/// nil for the root.
	var parentID: String?
	var entries: [BrowseEntry]
}

nonisolated extension LibraryCatalog {
	func page(_ id: String) throws(UPnPError) -> BrowsePage {
		let me = try metadata(id)
		let children = try children(id, start: 0, count: 0).objects
		return BrowsePage(id: id, title: me.title, parentID: id == "0" ? nil : me.parentID, entries: children.map(BrowseEntry.init))
	}
}
