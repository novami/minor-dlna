import Foundation

nonisolated enum MetaKind: String, Sendable {
	case movies, shows

	/// Wikidata classes accepted as a movie or a show, besides an entity with a TMDb ID of the right type.
	var classes: Set<String> {
		switch self {
		case .movies: ["Q11424", "Q24862", "Q506240", "Q202866", "Q229390"]
		case .shows: ["Q5398426", "Q1259759", "Q581714", "Q117467246", "Q15416"]
		}
	}

	var tmdbProperty: String { self == .movies ? "P4947" : "P4983" }
}

/// A search hit of the requested kind.
nonisolated struct MetaCandidate: Sendable, Equatable, Identifiable {
	var id: String // Wikidata Q-ID
	var title: String
	var description: String
	var year: Int?
	/// Labels and aliases the search matched, for scoring.
	var names: [String] = []
}

/// What gets stored for a matched movie or show.
nonisolated struct MetaDetails: Sendable, Equatable {
	var wikidata = ""
	var title = ""
	var origTitle: String?
	var year: Int?
	var overview: String?
	var genres: [String] = []
	var director: String?
	var cast: [String] = []
	var runtime: Int? // minutes
	var posterURL: URL?
}

nonisolated enum MetaError: LocalizedError {
	case notFound
	case http(Int, String)

	var errorDescription: String? {
		switch self {
		case .notFound: "Nenalezeno."
		case let .http(code, host): "\(host) odpověděl chybou \(code)."
		}
	}
}

/// Wikidata entity as returned by wbgetentities, read leniently.
nonisolated struct WikiEntity {
	let json: [String: Any]

	func label(_ langs: [String] = ["cs", "mul", "en"]) -> String {
		let labels = json["labels"] as? [String: [String: Any]] ?? [:]
		return langs.lazy.compactMap { labels[$0]?["value"] as? String }.first { !$0.isEmpty } ?? ""
	}

	var allLabels: [String] {
		(json["labels"] as? [String: [String: Any]] ?? [:]).values.compactMap { $0["value"] as? String }
	}

	var czechDescription: String {
		((json["descriptions"] as? [String: [String: Any]])?["cs"]?["value"] as? String) ?? ""
	}

	func sitelink(_ wiki: String) -> String? {
		(json["sitelinks"] as? [String: [String: Any]])?[wiki]?["title"] as? String
	}

	/// Claim values of a property, skipping deprecated statements.
	func values(_ prop: String) -> [Any] {
		let claims = (json["claims"] as? [String: [[String: Any]]])?[prop] ?? []
		return claims.compactMap { c in
			guard c["rank"] as? String != "deprecated" else { return nil }
			return ((c["mainsnak"] as? [String: Any])?["datavalue"] as? [String: Any])?["value"]
		}
	}

	func ids(_ prop: String) -> [String] { values(prop).compactMap { ($0 as? [String: Any])?["id"] as? String } }

	func string(_ prop: String) -> String? { values(prop).lazy.compactMap { $0 as? String }.first }

	/// The earliest year of the publication (or start) dates.
	var year: Int? {
		let years = ["P577", "P580"].flatMap(values).compactMap { v -> Int? in
			guard let t = (v as? [String: Any])?["time"] as? String, t.count >= 5 else { return nil }
			return Int(t.dropFirst().prefix(4)).flatMap { $0 > 0 ? $0 : nil }
		}
		return years.min()
	}

	func `is`(_ k: MetaKind) -> Bool {
		string(k.tmdbProperty) != nil || !k.classes.isDisjoint(with: ids("P31"))
	}

	/// Runtime in minutes (P2047, minutes or hours).
	var runtime: Int? {
		guard let q = values("P2047").first as? [String: Any], let amount = (q["amount"] as? String).flatMap({ Double($0.trimmingPrefix("+")) })
		else { return nil }
		let minutes = (q["unit"] as? String ?? "").hasSuffix("/Q25235") ? amount * 60 : amount
		return minutes > 0 ? Int(minutes.rounded()) : nil
	}
}

nonisolated struct WikidataClient: Sendable {
	static let api = URL(string: "https://www.wikidata.org/w/api.php")!
	static let userAgent = "MinorDLNA (https://github.com/novami/minor-dlna)"
	var session: URLSession = .shared

	private func get(_ url: URL) async throws -> Any {
		var req = URLRequest(url: url, timeoutInterval: 20)
		req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
		let (data, res) = try await session.data(for: req)
		let code = (res as? HTTPURLResponse)?.statusCode ?? 0
		if code == 404 { throw MetaError.notFound }
		guard code == 200 else { throw MetaError.http(code, url.host() ?? "") }
		return try JSONSerialization.jsonObject(with: data)
	}

	private func wikidata(_ params: [String: String]) async throws -> [String: Any] {
		// swiftlint:disable:next force_unwrapping
		var c = URLComponents(url: Self.api, resolvingAgainstBaseURL: false)!
		c.queryItems = (params.merging(["format": "json"]) { a, _ in a }).sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
		// swiftlint:disable:next force_unwrapping
		return try await get(c.url!) as? [String: Any] ?? [:]
	}

	func entities(_ ids: [String], props: String) async throws -> [String: WikiEntity] {
		var out: [String: WikiEntity] = [:]
		// wbgetentities takes at most 50 IDs.
		for chunk in stride(from: 0, to: ids.count, by: 50).map({ Array(ids[$0..<min($0 + 50, ids.count)]) }) {
			let r = try await wikidata(["action": "wbgetentities", "ids": chunk.joined(separator: "|"), "props": props,
			                            "languages": "cs|mul|en", "sitefilter": "cswiki|enwiki"])
			for (id, e) in r["entities"] as? [String: [String: Any]] ?? [:] where e["missing"] == nil { out[id] = WikiEntity(json: e) }
		}
		return out
	}

	/// Movies or shows by title; Czech labels first, missing accents are tolerated.
	func search(_ k: MetaKind, _ title: String) async throws -> [MetaCandidate] {
		let r = try await wikidata(["action": "wbsearchentities", "search": title, "language": "cs", "uselang": "cs", "type": "item", "limit": "12"])
		var ids: [String] = [], desc: [String: String] = [:], match: [String: String] = [:]
		for s in r["search"] as? [[String: Any]] ?? [] {
			guard let id = s["id"] as? String else { continue }
			ids.append(id)
			desc[id] = s["description"] as? String
			match[id] = (s["match"] as? [String: Any])?["text"] as? String
		}
		if ids.isEmpty {
			// Full-text search catches titles that are not a label prefix.
			let fr = try await wikidata(["action": "query", "list": "search", "srsearch": "\(title) haswbstatement:\(k.tmdbProperty)", "srlimit": "8"])
			ids = ((fr["query"] as? [String: Any])?["search"] as? [[String: Any]] ?? []).compactMap { $0["title"] as? String }
			if ids.isEmpty { return [] }
		}
		let ents = try await entities(ids, props: "labels|descriptions|claims")
		return ids.compactMap { id in
			guard let e = ents[id], e.is(k) else { return nil }
			return MetaCandidate(id: id, title: e.label(), description: desc[id].flatMap { $0.isEmpty ? nil : $0 } ?? e.czechDescription,
			                     year: e.year, names: e.allLabels + (match[id].map { [$0] } ?? []))
		}
	}

	/// The entity with labels of its genres and people, and the Wikipedia summary.
	func details(_ k: MetaKind, _ id: String) async throws -> MetaDetails {
		guard let e = try await entities([id], props: "labels|claims|sitelinks")[id], !e.label().isEmpty else { throw MetaError.notFound }
		var d = MetaDetails(wikidata: id, title: e.label(), year: e.year, runtime: e.runtime)
		d.origTitle = e.values("P1476").lazy.compactMap { ($0 as? [String: Any])?["text"] as? String }.first
		let genres = e.ids("P136"), director = Array(e.ids("P57").prefix(1)), cast = Array(e.ids("P161").prefix(10))
		if let names = try? await entities(genres + director + cast, props: "labels") {
			let name = { (id: String) in names[id]?.label() ?? "" }
			d.genres = Array(genres.map(name).filter { !$0.isEmpty }.prefix(3))
			d.director = director.map(name).first { !$0.isEmpty }
			d.cast = cast.map(name).filter { !$0.isEmpty }
		}
		// Czech article text; the English article more often has the poster as its image.
		for wiki in ["cs", "en"] {
			guard let title = e.sitelink("\(wiki)wiki"), let s = try? await summary(wiki, title) else { continue }
			if d.overview == nil, let x = s["extract"] as? String, !x.isEmpty { d.overview = x }
			if d.posterURL == nil, let t = s["thumbnail"] as? [String: Any], let w = t["width"] as? Int, let h = t["height"] as? Int, h > w,
			   let src = (t["source"] as? String).flatMap(URL.init(string:)) {
				d.posterURL = src
			}
		}
		return d
	}

	private func summary(_ wiki: String, _ title: String) async throws -> [String: Any] {
		// swiftlint:disable:next force_unwrapping
		let path = title.replacingOccurrences(of: " ", with: "_").addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~()")))!
		// swiftlint:disable:next force_unwrapping
		return try await get(URL(string: "https://\(wiki).wikipedia.org/api/rest_v1/page/summary/\(path)")!) as? [String: Any] ?? [:]
	}

	func download(_ url: URL, to dst: URL, limit: Int = 10 << 20) async throws {
		var req = URLRequest(url: url, timeoutInterval: 30)
		req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
		let (tmp, res) = try await session.download(for: req)
		defer { try? FileManager.default.removeItem(at: tmp) }
		let code = (res as? HTTPURLResponse)?.statusCode ?? 0
		guard code == 200 else { throw MetaError.http(code, url.host() ?? "") }
		guard ((try? FileManager.default.attributesOfItem(atPath: tmp.path)[.size] as? Int) ?? 0) <= limit else { throw MetaError.http(413, url.host() ?? "") }
		try? FileManager.default.removeItem(at: dst)
		try FileManager.default.moveItem(at: tmp, to: dst)
	}
}
