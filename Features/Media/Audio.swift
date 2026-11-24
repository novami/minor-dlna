import Foundation

/// Music metadata: the folder layout "Artist/Album/01 Title.ext" first, tags from ffprobe override it once probed.
nonisolated enum AudioMeta {
	static let unknownArtist = "Neznámý interpret"
	// swiftlint:disable:next force_try
	private static let trackPrefix = try! NSRegularExpression(pattern: #"^(\d{1,3})[ ._-]+(.+)$"#)

	/// rel is relative to the library root, already NFC.
	static func fromLayout(rel: String, path: String) -> Described {
		let stem = Names.stripExt((rel as NSString).lastPathComponent)
		var d = Described(title: stem, sortTitle: stem)
		let ns = stem as NSString
		if let m = trackPrefix.firstMatch(in: stem, range: NSRange(location: 0, length: ns.length)) {
			d.title = ns.substring(with: m.range(at: 2))
			d.sortTitle = d.title
			d.track = Int(ns.substring(with: m.range(at: 1)))
		}
		let dirs = (rel as NSString).deletingLastPathComponent.split(separator: "/").map(String.init)
		if let album = dirs.last { d.album = album }
		if dirs.count >= 2 { d.artist = dirs[dirs.count - 2] }
		d.albumArtist = d.artist
		d.hasArt = folderCover((path as NSString).deletingLastPathComponent) != nil
		return d
	}

	/// Tags win over the layout; missing tags keep what the layout gave.
	static func merge(_ d: Described, _ p: ProbeInfo) -> Described {
		var d = d
		if let t = p.tag("title") { d.title = t; d.sortTitle = t }
		if let a = p.tag("artist") { d.artist = a }
		if let a = p.tag("album_artist", "albumartist", "album artist") ?? p.tag("artist") { d.albumArtist = a }
		if let a = p.tag("album") { d.album = a }
		if let g = p.tag("genre") { d.genre = g }
		if let y = ProbeInfo.number(p.tag("date", "year")), y > 1000 { d.year = y }
		if let t = ProbeInfo.number(p.tag("track", "tracknumber")) { d.track = t }
		if let n = ProbeInfo.number(p.tag("disc", "discnumber")) { d.disc = n }
		if p.hasPicture { d.hasArt = true }
		return d
	}

	/// cover / folder / front / album .jpg|.jpeg|.png next to the file, in that preference.
	static func folderCover(_ dir: String) -> String? {
		guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return nil }
		for want in ["cover", "folder", "front", "album"] {
			if let n = names.first(where: {
				let ext = ($0 as NSString).pathExtension.lowercased()
				return ["jpg", "jpeg", "png"].contains(ext) && Names.stripExt($0).lowercased() == want
			}) {
				return (dir as NSString).appendingPathComponent(n)
			}
		}
		return nil
	}
}
