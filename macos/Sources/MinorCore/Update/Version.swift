import Foundation

/// v1.2.3 or v1.2.3-rc.1; a pre-release sorts before its release.
public struct Version: Comparable, Sendable, CustomStringConvertible {
	let numbers: [Int]
	let pre: String

	public init?(_ s: String) {
		guard s.hasPrefix("v") else { return nil }
		let rest = s.dropFirst()
		let core = rest.prefix { $0 != "-" }
		let parts = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
		guard parts.count == 3, parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
		numbers = parts.map { $0! }
		pre = core.count < rest.count ? String(rest.dropFirst(core.count + 1)) : ""
		guard pre.isEmpty || pre.wholeMatch(of: /(alpha|beta|rc)(\.\d+)?/) != nil else { return nil }
	}

	/// The release a build comes from: "v0.1.1-9-g22cac2e-dirty" from git describe is a local build on top of v0.1.1,
	/// so any newer release replaces it.
	public static func base(of build: String) -> Version? {
		if let m = build.wholeMatch(of: /(v\d+\.\d+\.\d+(?:-(?:alpha|beta|rc)(?:\.\d+)?)?)(?:-\d+-g[0-9a-f]+)?(?:-dirty)?/) {
			return Version(String(m.1))
		}
		return nil
	}

	public var description: String { "v" + numbers.map(String.init).joined(separator: ".") + (pre.isEmpty ? "" : "-" + pre) }

	public static func < (a: Version, b: Version) -> Bool {
		if a.numbers != b.numbers { return a.numbers.lexicographicallyPrecedes(b.numbers) }
		if a.pre == b.pre { return false }
		if a.pre.isEmpty { return false }
		if b.pre.isEmpty { return true }
		return a.pre.compare(b.pre, options: .numeric) == .orderedAscending
	}

	public static func == (a: Version, b: Version) -> Bool { a.numbers == b.numbers && a.pre == b.pre }
}
