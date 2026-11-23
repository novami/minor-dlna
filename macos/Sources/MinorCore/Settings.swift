import Foundation

public enum LibraryType: String, Codable, CaseIterable, Sendable {
	case movies, shows, videos, photos, music
}

public struct Library: Codable, Equatable, Identifiable, Sendable {
	public var id: UUID
	public var name: String
	public var type: LibraryType
	public var paths: [String]

	public init(id: UUID = UUID(), name: String, type: LibraryType, paths: [String]) {
		self.id = id
		self.name = name
		self.type = type
		self.paths = paths
	}
}

/// User settings, stored as settings.json. Missing keys fall back to defaults, so new fields need no migration.
public struct Settings: Codable, Equatable, Sendable {
	public var name: String
	/// Stable UPnP device UUID, generated once.
	public var uuid: UUID
	public var port: Int
	public var libraries: [Library]
	/// Look for new versions periodically.
	public var autoCheck: Bool
	/// Download and install a found version without asking (needs `autoCheck`).
	public var autoUpdate: Bool
	/// Czech titles, overviews and posters of movies and shows from Wikidata and Wikipedia.
	public var metadata: Bool
	public var transcode: TranscodeSettings
	public var remote: RemoteSettings
	/// After an episode played to the end on a TV, the next one starts.
	public var autoNextEpisode: Bool

	public init(name: String = Host.current().localizedName ?? "MinorDLNA", uuid: UUID = UUID(), port: Int = 8200,
	            libraries: [Library] = [], autoCheck: Bool = true, autoUpdate: Bool = true, transcode: TranscodeSettings = .init(), remote: RemoteSettings = .init(), metadata: Bool = true,
	            autoNextEpisode: Bool = false) {
		self.name = name
		self.uuid = uuid
		self.port = port
		self.libraries = libraries
		self.autoCheck = autoCheck
		self.autoUpdate = autoUpdate
		self.metadata = metadata
		self.transcode = transcode
		self.remote = remote
		self.autoNextEpisode = autoNextEpisode
	}

	public init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		let d = Settings()
		name = try c.decodeIfPresent(String.self, forKey: .name) ?? d.name
		uuid = try c.decodeIfPresent(UUID.self, forKey: .uuid) ?? d.uuid
		port = try c.decodeIfPresent(Int.self, forKey: .port) ?? d.port
		libraries = try c.decodeIfPresent([Library].self, forKey: .libraries) ?? d.libraries
		autoCheck = try c.decodeIfPresent(Bool.self, forKey: .autoCheck) ?? d.autoCheck
		autoUpdate = try c.decodeIfPresent(Bool.self, forKey: .autoUpdate) ?? d.autoUpdate
		metadata = try c.decodeIfPresent(Bool.self, forKey: .metadata) ?? d.metadata
		transcode = try c.decodeIfPresent(TranscodeSettings.self, forKey: .transcode) ?? d.transcode
		remote = try c.decodeIfPresent(RemoteSettings.self, forKey: .remote) ?? d.remote
		autoNextEpisode = try c.decodeIfPresent(Bool.self, forKey: .autoNextEpisode) ?? d.autoNextEpisode
	}

	public static let portRange = 1024...65535
}

public struct TranscodeSettings: Codable, Equatable, Sendable {
	/// Encode and decode with VideoToolbox.
	public var hardware: Bool
	/// Concurrent ffmpeg processes.
	public var maxSessions: Int
	/// The TV decodes DTS (differs by model line).
	public var dts: Bool
	/// Device IP → profile id chosen by hand; others are detected.
	public var clients: [String: String]

	public init(hardware: Bool = true, maxSessions: Int = 2, dts: Bool = true, clients: [String: String] = [:]) {
		self.hardware = hardware
		self.maxSessions = maxSessions
		self.dts = dts
		self.clients = clients
	}

	public static let sessionRange = 1...4

	public init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		let d = TranscodeSettings()
		hardware = try c.decodeIfPresent(Bool.self, forKey: .hardware) ?? d.hardware
		maxSessions = max(try c.decodeIfPresent(Int.self, forKey: .maxSessions) ?? d.maxSessions, 1)
		dts = try c.decodeIfPresent(Bool.self, forKey: .dts) ?? d.dts
		clients = try c.decodeIfPresent([String: String].self, forKey: .clients) ?? d.clients
	}
}

public enum SettingsStore {
	public static var defaultURL: URL { AppPaths.support.appending(path: "settings.json") }

	/// Returns defaults when the file does not exist yet; a damaged file is an error, so it is never overwritten silently.
	public static func load(from url: URL = defaultURL) throws -> Settings {
		guard FileManager.default.fileExists(atPath: url.path) else { return Settings() }
		return try JSONDecoder().decode(Settings.self, from: Data(contentsOf: url))
	}

	public static func save(_ settings: Settings, to url: URL = defaultURL) throws {
		try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
		let enc = JSONEncoder()
		enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
		try enc.encode(settings).write(to: url, options: .atomic)
	}
}
