import Foundation

/// Decides which search hit a file name means.
enum TitleMatch {
	/// Title similarity scores.
	static let hit = 1.0 // returned by the search
	static let prefix = 1.5 // the name starts with the title, e.g. "Film 3" vs "Film 3: Subtitle"
	static let exact = 2.0 // same title, ignoring case, accents and punctuation

	/// Lower-cased, without accents, punctuation turned into single spaces.
	static func normalize(_ s: String) -> String {
		let folded = s.lowercased().folding(options: .diacriticInsensitive, locale: nil)
		return folded.split { !($0.isLetter || $0.isNumber) }.joined(separator: " ")
	}

	static func similarity(_ title: String, _ names: [String]) -> Double {
		let q = normalize(title)
		// "Film 1" is usually just "Film".
		let alt = q.hasSuffix(" 1") ? String(q.dropLast(2)) : q
		var best = hit
		for n in names.map(normalize) where !n.isEmpty {
			if n == q || n == alt { return exact }
			if n.hasPrefix(q + " ") { best = prefix }
		}
		return best
	}

	/// The candidate a file name means, or nil when it is not clear.
	static func choose(_ title: String, year: Int?, _ cands: [MetaCandidate]) -> MetaCandidate? {
		var ok: [(c: MetaCandidate, title: Double, total: Double)] = []
		for c in cands {
			let t = similarity(title, [c.title] + c.names)
			var total = t
			if let year, let cy = c.year {
				switch abs(cy - year) {
				case 0: total += 2
				case 1: total += 1
				default: continue
				}
			}
			ok.append((c, t, total))
		}
		guard var best = ok.first else { return nil }
		var tie = false
		for s in ok.dropFirst() {
			if s.total > best.total { (best, tie) = (s, false) } else if s.total == best.total { tie = true }
		}
		if tie { return nil }
		let near = ok.filter { $0.title >= prefix }.count
		return best.total >= 3 || best.title == exact || (near == 1 && best.title >= prefix) ? best.c : nil
	}

	/// The parsed title, and without a trailing " - extra words" that release names often carry.
	static func searchTitles(_ title: String) -> [String] {
		guard let r = title.range(of: " - "), r.lowerBound > title.startIndex else { return [title] }
		return [title, String(title[..<r.lowerBound])]
	}
}
