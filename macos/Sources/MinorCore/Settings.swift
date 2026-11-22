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
	public var autoUpdate: Bool

	public init(name: String = Host.current().localizedName ?? "MinorDLNA", uuid: UUID = UUID(), port: Int = 8200,
	            libraries: [Library] = [], autoUpdate: Bool = true) {
		self.name = name
		self.uuid = uuid
		self.port = port
		self.libraries = libraries
		self.autoUpdate = autoUpdate
	}

	public init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		let d = Settings()
		name = try c.decodeIfPresent(String.self, forKey: .name) ?? d.name
		uuid = try c.decodeIfPresent(UUID.self, forKey: .uuid) ?? d.uuid
		port = try c.decodeIfPresent(Int.self, forKey: .port) ?? d.port
		libraries = try c.decodeIfPresent([Library].self, forKey: .libraries) ?? d.libraries
		autoUpdate = try c.decodeIfPresent(Bool.self, forKey: .autoUpdate) ?? d.autoUpdate
	}

	public static let portRange = 1024...65535
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
