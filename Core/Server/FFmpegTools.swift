import Foundation

/// ffmpeg and ffprobe ship inside the app (Contents/Helpers); nothing is looked up in PATH or downloaded.
nonisolated enum FFmpegTools {
	/// MINORDLNA_FFMPEG_DIR points tests and development runs at a build outside the bundle.
	static var directory: URL {
		if let dir = ProcessInfo.processInfo.environment["MINORDLNA_FFMPEG_DIR"] { return URL(filePath: dir, directoryHint: .isDirectory) }
		return Bundle.main.bundleURL.appending(path: "Contents/Helpers", directoryHint: .isDirectory)
	}

	static func path(_ tool: String) -> String? {
		let p = directory.appending(path: tool).path
		return FileManager.default.isExecutableFile(atPath: p) ? p : nil
	}
}
