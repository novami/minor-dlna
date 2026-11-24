import Foundation

nonisolated enum LibraryType: String, Codable, CaseIterable, Sendable {
	case movies, shows, videos, photos, music
}

nonisolated struct Library: Codable, Equatable, Identifiable, Sendable {
	var id: UUID
	var name: String
	var type: LibraryType
	var paths: [String]
	/// Bookmarks of the folders by the path they were made for, so a moved or renamed folder is found again.
	var bookmarks: [String: Data]?

	init(id: UUID = UUID(), name: String, type: LibraryType, paths: [String], bookmarks: [String: Data]? = nil) {
		self.id = id
		self.name = name
		self.type = type
		self.paths = paths
		self.bookmarks = bookmarks
	}
}

/// User settings, stored as settings.json. Missing keys fall back to defaults, so new fields need no migration.
nonisolated struct Settings: Codable, Equatable, Sendable {
	var name: String
	/// Stable UPnP device UUID, generated once.
	var uuid: UUID
	var port: Int
	var libraries: [Library]
	/// Czech titles, overviews and posters of movies and shows from Wikidata and Wikipedia.
	var metadata: Bool
	var transcode: TranscodeSettings
	var remote: RemoteSettings
	/// After an episode played to the end on a TV, the next one starts.
	var autoNextEpisode: Bool

	init(
		name: String = Host.current().localizedName ?? "MinorDLNA", uuid: UUID = UUID(), port: Int = 8200,
		libraries: [Library] = [], transcode: TranscodeSettings = .init(), remote: RemoteSettings = .init(), metadata: Bool = true,
		autoNextEpisode: Bool = false
	) {
		self.name = name
		self.uuid = uuid
		self.port = port
		self.libraries = libraries
		self.metadata = metadata
		self.transcode = transcode
		self.remote = remote
		self.autoNextEpisode = autoNextEpisode
	}

	init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		let d = Settings()
		name = try c.decodeIfPresent(String.self, forKey: .name) ?? d.name
		uuid = try c.decodeIfPresent(UUID.self, forKey: .uuid) ?? d.uuid
		port = try c.decodeIfPresent(Int.self, forKey: .port) ?? d.port
		libraries = try c.decodeIfPresent([Library].self, forKey: .libraries) ?? d.libraries
		metadata = try c.decodeIfPresent(Bool.self, forKey: .metadata) ?? d.metadata
		transcode = try c.decodeIfPresent(TranscodeSettings.self, forKey: .transcode) ?? d.transcode
		remote = try c.decodeIfPresent(RemoteSettings.self, forKey: .remote) ?? d.remote
		autoNextEpisode = try c.decodeIfPresent(Bool.self, forKey: .autoNextEpisode) ?? d.autoNextEpisode
	}

	static let portRange = 1024...65535
}

nonisolated struct TranscodeSettings: Codable, Equatable, Sendable {
	/// Concurrent ffmpeg processes.
	var maxSessions: Int
	/// The TV decodes DTS (differs by model line).
	var dts: Bool
	/// Device IP → profile id chosen by hand; others are detected.
	var clients: [String: String]

	init(maxSessions: Int = 2, dts: Bool = true, clients: [String: String] = [:]) {
		self.maxSessions = maxSessions
		self.dts = dts
		self.clients = clients
	}

	static let sessionRange = 1...4

	init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		let d = TranscodeSettings()
		maxSessions = max(try c.decodeIfPresent(Int.self, forKey: .maxSessions) ?? d.maxSessions, 1)
		dts = try c.decodeIfPresent(Bool.self, forKey: .dts) ?? d.dts
		clients = try c.decodeIfPresent([String: String].self, forKey: .clients) ?? d.clients
	}
}

nonisolated enum SettingsStore {
	static var defaultURL: URL { AppPaths.support.appending(path: "settings.json") }

	/// Returns defaults when the file does not exist yet; a damaged file is an error, so it is never overwritten silently.
	static func load(from url: URL = defaultURL) throws -> Settings {
		guard FileManager.default.fileExists(atPath: url.path) else { return Settings() }
		return try JSONDecoder().decode(Settings.self, from: Data(contentsOf: url))
	}

	static func save(_ settings: Settings, to url: URL = defaultURL) throws {
		try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
		let enc = JSONEncoder()
		enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
		try enc.encode(settings).write(to: url, options: .atomic)
	}
}
