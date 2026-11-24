import Foundation

/// What the overview window shows; taken on request, cheap enough to poll every few seconds.
nonisolated struct ServerStatus: Sendable, Equatable {
	var libraries: [LibraryStatus]
	var scanning: Bool
	var transcodes: [TranscodeSession]
	var clients: [ClientInfo]
	/// ffmpeg found: transcoding, video thumbnails and cover art work.
	var ffmpeg: Bool
	/// ffprobe found: durations, codecs and music tags.
	var ffprobe: Bool
}

nonisolated struct LibraryStatus: Sendable, Equatable, Identifiable {
	var id: UUID
	var items: Int
	/// Videos and songs whose duration and codecs are not known yet.
	var probing: Int
	/// Some folder of the library is not reachable (unmounted disk).
	var missingPaths: [String]
}

nonisolated struct TranscodeSession: Sendable, Equatable, Identifiable {
	let id: UUID
	let title: String
	let client: String
	/// Plan key, e.g. "copy-aac".
	let plan: String
	let began: Date

	init(title: String, client: String, plan: String) {
		id = UUID()
		self.title = title
		self.client = client
		self.plan = plan
		began = .now
	}
}

nonisolated struct ClientInfo: Sendable, Equatable, Identifiable {
	var id: String { ip }
	var ip: String
	/// User-Agent and X-AV-Client-Info seen from the address.
	var ident: String
	/// Profile detected from ident.
	var detected: String
	/// Profile chosen by the user; nil means automatic.
	var chosen: String?
	var lastSeen: Date
}

nonisolated struct ProfileOption: Sendable, Hashable, Identifiable {
	let id: String
	let label: String

	static let all = [
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

	static func label(_ id: String) -> String { all.first { $0.id == id }?.label ?? id }
}

nonisolated extension Store {
	/// Items and items waiting for ffprobe per library row id.
	func counts() -> [Int64: (items: Int, probing: Int)] {
		let rows = (try? reader.query("""
			SELECT library_id, COUNT(*), SUM(probed = 0 AND (mime LIKE 'video/%' OR mime LIKE 'audio/%')) FROM item GROUP BY library_id
			""") { ($0.int64(0), $0.int(1), $0.int(2)) }) ?? []
		return Dictionary(rows.map { ($0.0, (items: $0.1, probing: $0.2)) }) { a, _ in a }
	}
}

/// Files the app can get again: thumbnails, TV-sized photos and posters (downloaded again on the next metadata pass).
nonisolated enum CacheStorage {
	static var dir: URL { URL.cachesDirectory.appending(path: AppPaths.bundleID, directoryHint: .isDirectory) }
	static var dirs: [URL] { [Thumbnails.defaultDir, MetadataService.defaultDir] }

	static func size() -> Int64 {
		var total: Int64 = 0
		for d in dirs {
			guard let e = FileManager.default.enumerator(at: d, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { continue }
			for case let url as URL in e {
				total += Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
			}
		}
		return total
	}

	static func clear() throws {
		for d in dirs where FileManager.default.fileExists(atPath: d.path) { try FileManager.default.removeItem(at: d) }
	}
}
