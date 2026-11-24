import Foundation

/// Only files inside the added libraries may be served or handed to ffmpeg. A path is resolved (symlinks, "..")
/// before it is compared, so a link or a crafted name cannot lead out of a library.
nonisolated struct PathGuard: Sendable {
	/// Resolved library roots.
	let roots: [String]

	init(roots: [String]) {
		self.roots = roots.map(Self.resolve)
	}

	static func resolve(_ path: String) -> String {
		URL(filePath: path).standardizedFileURL.resolvingSymlinksInPath().path
	}

	/// The real path when it lies inside a library, otherwise nil.
	func allowed(_ path: String) -> String? {
		let real = Self.resolve(path)
		return roots.contains { real == $0 || real.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") } ? real : nil
	}
}
