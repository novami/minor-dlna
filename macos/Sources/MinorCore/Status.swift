import Foundation

/// What the overview window shows; taken on request, cheap enough to poll every few seconds.
public struct ServerStatus: Sendable, Equatable {
	public var libraries: [LibraryStatus]
	public var scanning: Bool
	public var transcodes: [TranscodeSession]
	public var clients: [ClientInfo]
	/// ffmpeg found: transcoding, video thumbnails and cover art work.
	public var ffmpeg: Bool
	/// ffprobe found: durations, codecs and music tags.
	public var ffprobe: Bool
}

public struct LibraryStatus: Sendable, Equatable, Identifiable {
	public var id: UUID
	public var items: Int
	/// Videos and songs whose duration and codecs are not known yet.
	public var probing: Int
	/// Some folder of the library is not reachable (unmounted disk).
	public var missingPaths: [String]
}

public struct TranscodeSession: Sendable, Equatable, Identifiable {
	public let id: UUID
	public let title: String
	public let client: String
	/// Plan key, e.g. "copy-aac".
	public let plan: String
	public let began: Date

	init(title: String, client: String, plan: String) {
		id = UUID()
		self.title = title
		self.client = client
		self.plan = plan
		began = .now
	}
}

public struct ClientInfo: Sendable, Equatable, Identifiable {
	public var id: String { ip }
	public var ip: String
	/// User-Agent and X-AV-Client-Info seen from the address.
	public var ident: String
	/// Profile detected from ident.
	public var detected: String
	/// Profile chosen by the user; nil means automatic.
	public var chosen: String?
	public var lastSeen: Date
}

public struct ProfileOption: Sendable, Hashable, Identifiable {
	public let id: String
	public let label: String

	public static let all = [
		ProfileOption(id: "lg", label: "LG (webOS)"),
		ProfileOption(id: "samsung", label: "Samsung (Tizen)"),
		ProfileOption(id: "sony", label: "Sony Bravia"),
		ProfileOption(id: "panasonic", label: "Panasonic Viera"),
		ProfileOption(id: "hisense", label: "Hisense (VIDAA)"),
		ProfileOption(id: "android", label: "Android TV / Google TV (TCL, Philips, Xiaomi…)"),
		ProfileOption(id: "roku", label: "Roku TV (TCL, Hisense…)"),
		ProfileOption(id: "tv", label: "Jiná televize (bezpečné formáty)"),
		ProfileOption(id: Profile.generic.name, label: "Beze změny (počítač, přehrávač)"),
	]

	public static func label(_ id: String) -> String { all.first { $0.id == id }?.label ?? id }
}

extension Store {
	/// Items and items waiting for ffprobe per library row id.
	func counts() -> [Int64: (items: Int, probing: Int)] {
		let rows = (try? reader.query("""
			SELECT library_id, COUNT(*), SUM(probed = 0 AND (mime LIKE 'video/%' OR mime LIKE 'audio/%')) FROM item GROUP BY library_id
			""") { ($0.int64(0), $0.int(1), $0.int(2)) }) ?? []
		return Dictionary(rows.map { ($0.0, (items: $0.1, probing: $0.2)) }) { a, _ in a }
	}
}

/// Files the app can get again: thumbnails, TV-sized photos and posters (downloaded again on the next metadata pass).
public enum CacheStorage {
	public static var dir: URL { URL.cachesDirectory.appending(path: AppPaths.bundleID, directoryHint: .isDirectory) }
	static var dirs: [URL] { [Thumbnails.defaultDir, MetadataService.defaultDir] }

	public static func size() -> Int64 {
		var total: Int64 = 0
		for d in dirs {
			guard let e = FileManager.default.enumerator(at: d, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { continue }
			for case let url as URL in e {
				total += Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
			}
		}
		return total
	}

	public static func clear() throws {
		for d in dirs where FileManager.default.fileExists(atPath: d.path) { try FileManager.default.removeItem(at: d) }
	}
}
