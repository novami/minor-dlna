import Foundation

/// A library entry for the app and the web: a folder to open or an item to play.
public struct BrowseEntry: Sendable, Equatable, Identifiable, Encodable {
	public enum Kind: String, Sendable, Encodable {
		case folder, video, audio, image
	}

	public var id: String
	public var title: String
	public var kind: Kind
	public var childCount: Int?
	public var year: Int?
	public var durationMs: Int?
	public var positionMs: Int
	public var watched: Bool
	public var overview: String?
	/// Small image on this server: /poster/… or /thumb/….
	public var artPath: String?

	public var playable: Bool { kind == .video || kind == .audio }

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

public struct BrowsePage: Sendable, Equatable, Encodable {
	public var id: String
	public var title: String
	/// nil for the root.
	public var parentID: String?
	public var entries: [BrowseEntry]
}

extension LibraryCatalog {
	func page(_ id: String) throws(UPnPError) -> BrowsePage {
		let me = try metadata(id)
		let children = try children(id, start: 0, count: 0).objects
		return BrowsePage(id: id, title: me.title, parentID: id == "0" ? nil : me.parentID, entries: children.map(BrowseEntry.init))
	}
}
