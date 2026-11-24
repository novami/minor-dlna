import Foundation

nonisolated enum AppPaths {
	static let bundleID = "cz.novami.minor.dlna"
	/// Bundle ID of the 1.0 release, whose data is copied once.
	static let legacyBundleID = "cz.minordlna.app"

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

	/// Copies the settings and the index of the 1.0 release, once and only when the new folder does not exist yet.
	/// The index goes through SQLite itself (VACUUM INTO), because the old app may be running with a journal open.
	/// The old folder stays untouched; an index that cannot be copied is simply built again.
	@discardableResult
	static func migrateLegacyData(from old: URL = supportDirectory(legacyBundleID), to new: URL = support) -> Bool {
		let fm = FileManager.default
		guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) else { return false }
		do {
			try fm.createDirectory(at: new, withIntermediateDirectories: true)
			for name in try fm.contentsOfDirectory(atPath: old.path) where !name.hasPrefix("library.") {
				try fm.copyItem(at: old.appending(path: name), to: new.appending(path: name))
			}
		} catch {
			AppLog.app.error("data migration failed: \(error, privacy: .public)")
			try? fm.removeItem(at: new)
			return false
		}
		let index = old.appending(path: "library.sqlite")
		if fm.fileExists(atPath: index.path) {
			do {
				let db = try Database(path: index.path, readOnly: true)
				_ = try db.run("VACUUM INTO ?", new.appending(path: "library.sqlite").path)
			} catch {
				AppLog.app.error("index migration failed, it will be built again: \(error, privacy: .public)")
			}
		}
		AppLog.app.info("copied data of the 1.0 release")
		return true
	}
}
