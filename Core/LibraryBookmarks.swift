import Foundation

/// Library folders are kept as bookmarks next to their paths, so they survive a move or a rename.
nonisolated enum LibraryBookmarks {
	/// A folder whose path is gone is followed through its bookmark; every existing folder gets a current bookmark.
	static func refresh(_ libraries: [Library]) -> [Library] {
		libraries.map { library in
			var updated = library
			var marks: [String: Data] = [:]
			updated.paths = library.paths.map { path in
				var current = path
				let old = library.bookmarks?[path]
				if !exists(path), let old, let moved = resolve(old), exists(moved) { current = moved }
				if exists(current) {
					marks[current] = (current == path ? old : nil) ?? bookmark(current) ?? old
				} else if let old {
					marks[current] = old
				}
				return current
			}
			updated.bookmarks = marks.isEmpty ? nil : marks
			return updated
		}
	}

	static func bookmark(_ path: String) -> Data? { try? URL(filePath: path).bookmarkData() }

	/// Where the bookmarked folder is now; nil when it cannot be found.
	static func resolve(_ data: Data) -> String? {
		var stale = false
		guard let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting], relativeTo: nil,
		                         bookmarkDataIsStale: &stale) else { return nil }
		return url.standardizedFileURL.path(percentEncoded: false).replacingOccurrences(of: #"/$"#, with: "", options: .regularExpression)
	}

	private static func exists(_ path: String) -> Bool {
		var isDirectory: ObjCBool = false
		return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
	}
}
