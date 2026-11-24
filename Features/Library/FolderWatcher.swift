import CoreServices
import Foundation

/// Reports changed paths under the watched folders through FSEvents (one stream, no descriptor per file).
/// Network volumes may not deliver events, so the scanner keeps its periodic folder check.
nonisolated final class FolderWatcher: @unchecked Sendable {
	private var stream: FSEventStreamRef?
	private let queue = DispatchQueue(label: "cz.minordlna.fsevents")
	private let handler: @Sendable ([String]) -> Void

	init?(paths: [String], latency: TimeInterval, handler: @escaping @Sendable ([String]) -> Void) {
		self.handler = handler
		guard !paths.isEmpty else { return nil }
		var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
		let callback: FSEventStreamCallback = { _, info, _, paths, _, _ in
			guard let info, let changed = unsafeBitCast(paths, to: NSArray.self) as? [String] else { return }
			Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue().handler(changed)
		}
		let flags = kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot
		guard let s = FSEventStreamCreate(nil, callback, &ctx, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
		                                  latency, FSEventStreamCreateFlags(flags)) else { return nil }
		stream = s
		FSEventStreamSetDispatchQueue(s, queue)
		FSEventStreamStart(s)
	}

	deinit {
		guard let stream else { return }
		FSEventStreamStop(stream)
		FSEventStreamInvalidate(stream)
		FSEventStreamRelease(stream)
	}

	/// Real path as FSEvents reports it (/private/var, resolved symlinks); the path itself when it does not exist.
	static func realPath(_ path: String) -> String {
		guard let p = realpath(path, nil) else { return path }
		defer { free(p) }
		return String(cString: p)
	}

	/// Libraries whose roots contain a changed path; changes to hidden files (.DS_Store, ._ copies) are ignored.
	static func libraries(for changed: [String], roots: [(root: String, id: Int64)]) -> Set<Int64> {
		var ids: Set<Int64> = []
		for path in changed {
			for (root, id) in roots where !ids.contains(id) {
				guard path == root || path.hasPrefix(root + "/") || root.hasPrefix(path + "/") else { continue }
				let rel = path.count > root.count ? path.dropFirst(root.count + 1) : ""
				if !rel.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { ids.insert(id) }
			}
		}
		return ids
	}
}
