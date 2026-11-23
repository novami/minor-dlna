import CryptoKit
import Foundation

public struct Release: Sendable, Equatable {
	public var version: String
	public var notes: String
	public var url: URL?
	var zip: URL
	var zipName: String
	var sums: URL
	var signature: URL
}

public enum UpdateError: LocalizedError {
	case github(Int)
	case badSignature
	case badChecksum
	case tooLarge
	case badArchive(String)
	case selfCheck(String)
	case notWritable(String)

	public var errorDescription: String? {
		switch self {
		case let .github(code): "GitHub odpověděl chybou \(code)."
		case .badSignature: "Podpis vydání nesouhlasí."
		case .badChecksum: "Kontrolní součet staženého souboru nesouhlasí."
		case .tooLarge: "Stažený soubor je příliš velký."
		case let .badArchive(why): "Archiv vydání je poškozený: \(why)"
		case let .selfCheck(why): "Stažená aplikace neprošla kontrolou: \(why)"
		case let .notWritable(dir): "Do složky \(dir) nelze zapisovat."
		}
	}
}

/// Updates from GitHub Releases: MinorDLNA-<v>-macos.zip, checksums.txt (shasum) and checksums.txt.sig
/// (base64 Ed25519 of checksums.txt). The old bundle stays as <app>.prev until the new one has run for a while.
public struct Updater: Sendable {
	/// The private key lives only in the release pipeline's secrets.
	public static let publicKey = "Hz0MB/1WowAdMO3+gb14qztCqTHYy0KKzeKVrC5RuGE="
	static let repo = "novami/minor-dlna"
	static let maxDownload = 300 << 20

	var api = URL(string: "https://api.github.com")!
	var publicKey = Updater.publicKey
	var session = URLSession(configuration: .ephemeral)

	public init() {}

	/// The newest release above the running build, or nil.
	public func latest(current: String, prerelease: Bool = false) async throws -> Release? {
		struct GH: Decodable {
			struct Asset: Decodable {
				var name: String
				var browser_download_url: URL
			}
			var tag_name: String
			var body: String?
			var html_url: URL?
			var draft: Bool
			var prerelease: Bool
			var assets: [Asset]
		}
		let data = try await get(api.appending(path: "repos/\(Self.repo)/releases").appending(queryItems: [.init(name: "per_page", value: "20")]),
		                         accept: "application/vnd.github+json", limit: 4 << 20)
		var best: (Version, Release)?
		for r in try JSONDecoder().decode([GH].self, from: data) where !r.draft && (prerelease || !r.prerelease) {
			guard let v = Version(r.tag_name), best.map({ v > $0.0 }) ?? true else { continue }
			let asset = { (match: (String) -> Bool) in r.assets.first { match($0.name) } }
			guard let zip = asset({ $0.hasSuffix("-macos.zip") }), let sums = asset({ $0 == "checksums.txt" }),
			      let sig = asset({ $0 == "checksums.txt.sig" }) else { continue }
			best = (v, Release(version: r.tag_name, notes: r.body ?? "", url: r.html_url, zip: zip.browser_download_url, zipName: zip.name,
			                   sums: sums.browser_download_url, signature: sig.browser_download_url))
		}
		guard let best, let base = Version.base(of: current), best.0 > base else { return nil }
		return best.1
	}

	/// Downloads, verifies and swaps the bundle at app; the caller relaunches it.
	public func install(_ rel: Release, at app: URL) async throws {
		let fm = FileManager.default
		let parent = app.deletingLastPathComponent()
		guard fm.isWritableFile(atPath: parent.path) else { throw UpdateError.notWritable(parent.path) }
		// Same volume as the app, so the swap is a rename.
		let work = parent.appending(path: ".minordlna-update-\(UUID().uuidString)")
		try fm.createDirectory(at: work, withIntermediateDirectories: false)
		defer { try? fm.removeItem(at: work) }

		let sums = try await get(rel.sums, limit: 1 << 20)
		let sig = try await get(rel.signature, limit: 4 << 10)
		guard Self.verify(sums, signature: sig, publicKey: publicKey) else { throw UpdateError.badSignature }
		guard let want = Self.checksum(in: sums, for: rel.zipName) else { throw UpdateError.badArchive("checksums.txt nemá \(rel.zipName)") }

		let (tmp, res) = try await session.download(from: rel.zip)
		defer { try? fm.removeItem(at: tmp) }
		guard (res as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.github((res as? HTTPURLResponse)?.statusCode ?? 0) }
		guard let size = try fm.attributesOfItem(atPath: tmp.path)[.size] as? Int, size <= Self.maxDownload else { throw UpdateError.tooLarge }
		guard try Self.sha256(of: tmp) == want else { throw UpdateError.badChecksum }

		let unpacked = work.appending(path: "unpacked")
		try Self.run("/usr/bin/ditto", ["-x", "-k", tmp.path, unpacked.path])
		let entries = try fm.contentsOfDirectory(atPath: unpacked.path).filter { $0 != "__MACOSX" }
		guard entries == ["MinorDLNA.app"] else { throw UpdateError.badArchive("obsahuje \(entries.joined(separator: ", "))") }
		let new = unpacked.appending(path: "MinorDLNA.app")
		try Self.check(new, version: rel.version, like: app)

		let prev = Self.previous(of: app)
		try? fm.removeItem(at: prev)
		try fm.moveItem(at: app, to: prev)
		do { try fm.moveItem(at: new, to: app) } catch {
			try? fm.moveItem(at: prev, to: app)
			throw error
		}
	}

	public static func previous(of app: URL) -> URL { app.deletingLastPathComponent().appending(path: app.lastPathComponent + ".prev") }

	/// The new bundle must be ours, of the announced version and validly signed.
	static func check(_ new: URL, version: String, like app: URL) throws {
		// Read the plists directly: Bundle caches instances by path, and the app path keeps its old contents.
		let plist = { (u: URL) in
			(try? Data(contentsOf: u.appending(path: "Contents/Info.plist")))
				.flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
		}
		guard let info = plist(new) else { throw UpdateError.selfCheck("chybí Info.plist") }
		let want = plist(app)?["CFBundleIdentifier"] as? String ?? AppPaths.bundleID
		guard info["CFBundleIdentifier"] as? String == want else {
			throw UpdateError.selfCheck("jiná aplikace (\(info["CFBundleIdentifier"] as? String ?? "?"))")
		}
		guard info["MinorDLNABuild"] as? String == version else {
			throw UpdateError.selfCheck("verze \(info["MinorDLNABuild"] as? String ?? "?") místo \(version)")
		}
		do { try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", new.path]) } catch {
			throw UpdateError.selfCheck("neplatný podpis kódu")
		}
	}

	static func verify(_ data: Data, signature: Data, publicKey: String) -> Bool {
		guard let raw = Data(base64Encoded: publicKey), let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw),
		      let sig = Data(base64Encoded: String(decoding: signature, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
		else { return false }
		return key.isValidSignature(sig, for: data)
	}

	/// "<sha256>  <name>" lines as written by shasum.
	static func checksum(in sums: Data, for name: String) -> String? {
		for line in String(decoding: sums, as: UTF8.self).split(whereSeparator: \.isNewline) {
			let f = line.split(whereSeparator: \.isWhitespace)
			if f.count == 2, f[1].trimmingPrefix("*") == name, f[0].count == 64 { return f[0].lowercased() }
		}
		return nil
	}

	static func sha256(of url: URL) throws -> String {
		let fh = try FileHandle(forReadingFrom: url)
		defer { try? fh.close() }
		var h = SHA256()
		while let chunk = try fh.read(upToCount: 1 << 20), !chunk.isEmpty { h.update(data: chunk) }
		return h.finalize().map { String(format: "%02x", $0) }.joined()
	}

	private func get(_ url: URL, accept: String? = nil, limit: Int) async throws -> Data {
		var req = URLRequest(url: url, timeoutInterval: 60)
		req.setValue("MinorDLNA-updater", forHTTPHeaderField: "User-Agent")
		if let accept { req.setValue(accept, forHTTPHeaderField: "Accept") }
		let (data, res) = try await session.data(for: req)
		let code = (res as? HTTPURLResponse)?.statusCode ?? 0
		guard code == 200 else { throw UpdateError.github(code) }
		guard data.count <= limit else { throw UpdateError.tooLarge }
		return data
	}

	static func run(_ tool: String, _ args: [String]) throws {
		let p = Process()
		p.executableURL = URL(filePath: tool)
		p.arguments = args
		p.standardOutput = FileHandle.nullDevice
		p.standardError = FileHandle.nullDevice
		try p.run()
		p.waitUntilExit()
		guard p.terminationStatus == 0 else { throw UpdateError.badArchive("\((tool as NSString).lastPathComponent) skončil chybou \(p.terminationStatus)") }
	}
}
