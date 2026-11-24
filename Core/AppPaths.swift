import Foundation

nonisolated enum AppPaths {
	static let bundleID = "cz.novami.minor.dlna"

	/// ~/Library/Application Support/<bundle id>; MINORDLNA_SUPPORT_DIR points development runs and tests elsewhere.
	static var support: URL {
		if let dir = ProcessInfo.processInfo.environment["MINORDLNA_SUPPORT_DIR"] { return URL(filePath: dir, directoryHint: .isDirectory) }
		// Tests never touch the data of the installed app.
		if NSClassFromString("XCTestCase") != nil { return FileManager.default.temporaryDirectory.appending(path: "minordlna-tests-support", directoryHint: .isDirectory) }
		return supportDirectory(bundleID)
	}

	/// ~/Library/Caches/<bundle id>
	static var caches: URL {
		if ProcessInfo.processInfo.environment["MINORDLNA_SUPPORT_DIR"] != nil || NSClassFromString("XCTestCase") != nil { return support.appending(path: "Caches", directoryHint: .isDirectory) }
		return URL.cachesDirectory.appending(path: bundleID, directoryHint: .isDirectory)
	}

	static func supportDirectory(_ id: String) -> URL {
		URL.applicationSupportDirectory.appending(path: id, directoryHint: .isDirectory)
	}
}
