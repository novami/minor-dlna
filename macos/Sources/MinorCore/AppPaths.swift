import Foundation
import os

public enum AppPaths {
	public static let bundleID = "cz.minordlna.app"

	/// ~/Library/Application Support/cz.minordlna.app — separate from the old Go version's MinorDLNA folder.
	public static var support: URL {
		URL.applicationSupportDirectory.appending(path: bundleID, directoryHint: .isDirectory)
	}
}

/// Logs go to the unified log: `log stream --predicate 'subsystem == "cz.minordlna.app"'`.
public enum Log {
	public static let app = Logger(subsystem: AppPaths.bundleID, category: "app")
	public static let settings = Logger(subsystem: AppPaths.bundleID, category: "settings")
	public static let server = Logger(subsystem: AppPaths.bundleID, category: "server")
	static let ssdp = Logger(subsystem: AppPaths.bundleID, category: "ssdp")
}
