import Foundation

nonisolated enum AppPaths {
	static let bundleID = "cz.novami.minor.dlna"
	/// Bundle ID of the 1.0 release, whose data is copied once.
	static let legacyBundleID = "cz.minordlna.app"

	/// ~/Library/Application Support/<bundle id>
	static var support: URL { supportDirectory(bundleID) }

	static func supportDirectory(_ id: String) -> URL {
		URL.applicationSupportDirectory.appending(path: id, directoryHint: .isDirectory)
	}

	/// Copies settings.json and the index of the 1.0 release, once and only into an empty folder. The old folder stays untouched.
	@discardableResult
	static func migrateLegacyData(from old: URL = supportDirectory(legacyBundleID), to new: URL = support) -> Bool {
		let fm = FileManager.default
		guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) else { return false }
		do {
			try fm.copyItem(at: old, to: new)
			AppLog.app.info("copied data of the 1.0 release")
			return true
		} catch {
			AppLog.app.error("data migration failed: \(error, privacy: .public)")
			return false
		}
	}
}
