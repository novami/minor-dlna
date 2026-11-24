import Foundation

/// Titles from file names: movies "Film.Name.2019.1080p.mkv", episodes "Show S01E02 Title", "Show 1x02", "Show/Season 1/02 Title".
nonisolated enum Names {
	struct Episode: Equatable {
		var show: String
		var season: Int
		var episode: Int
		var title: String
	}

	private static func re(_ p: String, _ opts: NSRegularExpression.Options = []) -> NSRegularExpression {
		// The patterns are literals in this file; a bad one fails on the first use in the tests.
		// swiftlint:disable:next force_try
		try! NSRegularExpression(pattern: p, options: opts)
	}

	private static let sxe = re(#"(?:^|[^a-z0-9])s(\d{1,2})[ ._-]?e(\d{1,3})(?:[-e]\d{1,3})*"#, .caseInsensitive)
	private static let nxn = re(#"(?:^|[^a-z0-9])(\d{1,2})x(\d{2,3})(?:[^a-z0-9]|$)"#, .caseInsensitive)
	private static let seasonDir = re(#"^(?:season|s[eé]rie|serie|sezona|sezóna|s)[ ._-]*(\d{1,2})$"#, .caseInsensitive)
	private static let leadNum = re(#"^(?:e|ep|episode|díl|dil)?[ ._-]*(\d{1,3})(?:[ ._-]+(.*))?$"#)
	private static let year = re(#"(?:^|[ ._(\[-])((?:19|20)\d{2})(?=[ ._)\]-]|$)"#)
	// swiftlint:disable:next line_length
	private static let junk = re(#"[ ._(\[-](?:2160p|1080p|1080i|720p|576p|480p|4k|uhd|hdr|hdr10|dv|bluray|blu-ray|bdrip|brrip|remux|web-?dl|webrip|web|hdtv|dvdrip|dvd|x264|x265|h264|h265|hevc|avc|xvid|aac|ac3|dts|atmos|10bit|proper|repack|extended|unrated|cz|czech|dabing|titulky|sk)(?:[ ._)\]-]|$)"#, .caseInsensitive)

	/// rel is the path relative to the library root.
	static func episode(_ rel: String) -> Episode? {
		let base = stripExt((rel as NSString).lastPathComponent) as NSString
		let dirs = (rel as NSString).deletingLastPathComponent.split(separator: "/").map(String.init)

		for r in [sxe, nxn] {
			guard let m = r.firstMatch(in: base as String, range: NSRange(location: 0, length: base.length)) else { continue }
			var ep = Episode(show: cleanName(base.substring(to: m.range.location)),
			                 season: Int(base.substring(with: m.range(at: 1))) ?? 0,
			                 episode: Int(base.substring(with: m.range(at: 2))) ?? 0,
			                 title: cleanTitle(base.substring(from: NSMaxRange(m.range))))
			if ep.show.isEmpty { ep.show = showFromDirs(dirs) }
			return ep.show.isEmpty ? nil : ep
		}
		// Folder layout: Show/Season 1/02 Title.ext
		if dirs.count >= 2, let season = capture(seasonDir, dirs[dirs.count - 1], 1).flatMap({ Int($0) }) {
			let name = cleanName(base as String) as NSString
			if let m = leadNum.firstMatch(in: name as String, range: NSRange(location: 0, length: name.length)) {
				let title = m.range(at: 2).location == NSNotFound ? "" : name.substring(with: m.range(at: 2))
				return Episode(show: cleanName(dirs[dirs.count - 2]), season: season,
				               episode: Int(name.substring(with: m.range(at: 1))) ?? 0, title: cleanTitle(title))
			}
		}
		return nil
	}

	/// Title and year (0 = unknown) of a movie file.
	static func movie(_ fileName: String) -> (title: String, year: Int) {
		let base = stripExt(fileName) as NSString
		// The last plausible year wins: "2001 A Space Odyssey (1968)".
		if let m = year.matches(in: base as String, range: NSRange(location: 0, length: base.length)).last {
			let t = cleanName(base.substring(to: m.range(at: 1).location))
			if !t.isEmpty { return (t, Int(base.substring(with: m.range(at: 1))) ?? 0) }
		}
		var s = base as String
		if let m = junk.firstMatch(in: s, range: NSRange(location: 0, length: base.length)), m.range.location > 0 {
			s = base.substring(to: m.range.location)
		}
		return (cleanName(s), 0)
	}

	private static func showFromDirs(_ dirs: [String]) -> String {
		dirs.last { capture(seasonDir, $0, 0) == nil }.map(cleanName) ?? ""
	}

	/// Separators become spaces; brackets and dashes at the ends go.
	static func cleanName(_ s: String) -> String {
		var s = s.contains(" ") ? s.replacingOccurrences(of: "_", with: " ")
			: s.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "_", with: " ")
		s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
		return s.trimmingCharacters(in: CharacterSet(charactersIn: " -([."))
	}

	/// Drops release tags from an episode title.
	private static func cleanTitle(_ s: String) -> String {
		let s = " " + s as NSString
		if let m = junk.firstMatch(in: s as String, range: NSRange(location: 0, length: s.length)) {
			return cleanName(s.substring(to: m.range.location))
		}
		return cleanName(s as String)
	}

	static func stripExt(_ name: String) -> String {
		let ext = (name as NSString).pathExtension
		return ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
	}

	private static func capture(_ r: NSRegularExpression, _ s: String, _ group: Int) -> String? {
		let ns = s as NSString
		guard let m = r.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)),
		      m.range(at: group).location != NSNotFound else { return nil }
		return ns.substring(with: m.range(at: group))
	}

	/// A key whose binary order is natural and Czech: case and accents ignored, except č ř š ž after their base letter,
	/// numbers compared by value.
	static func sortKey(_ s: String) -> String {
		let scalars = Array(s.lowercased().decomposedStringWithCanonicalMapping.unicodeScalars)
		var out = String.UnicodeScalarView()
		var i = 0
		while i < scalars.count {
			let c = scalars[i]
			if ("0"..."9").contains(c) {
				var j = i
				while j < scalars.count, ("0"..."9").contains(scalars[j]) { j += 1 }
				let digits = String(String.UnicodeScalarView(scalars[i..<j])).drop { $0 == "0" }
				out.append(contentsOf: (String(repeating: "0", count: max(8 - digits.count, 0)) + digits).unicodeScalars)
				i = j
				continue
			}
			if c == "\u{030C}", i > 0, "crsz".unicodeScalars.contains(scalars[i - 1]) {
				out.append("~") // caron sorts after every other letter
			} else if c.properties.generalCategory != .nonspacingMark {
				out.append(c)
			}
			i += 1
		}
		return String(out)
	}
}
