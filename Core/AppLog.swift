import MinorLog
import os

/// App-wide loggers; one category per area.
nonisolated enum AppLog {
	static let app = Log.logger("App")
	static let settings = Log.logger("Settings")
	static let server = Log.logger("Server")
	static let library = Log.logger("Library")
	static let ssdp = Log.logger("SSDP")
	static let transcode = Log.logger("Transcode")
	static let tv = Log.logger("TV")
	static let metadata = Log.logger("Metadata")
}
