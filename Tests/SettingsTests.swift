import Foundation
import XCTest
@testable import MinorDLNA

final class SettingsTests: XCTestCase {
	func testRoundTrip() throws {
		let url = FileManager.default.temporaryDirectory.appending(path: "minordlna-\(UUID())/settings.json")
		defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
		var s = Settings(name: "Obývák", port: 8300)
		s.libraries = [Library(name: "Filmy", type: .movies, paths: ["/Volumes/Data/Filmy"])]
		try SettingsStore.save(s, to: url)
		XCTAssertTrue(try SettingsStore.load(from: url) == s)
	}

	func testMissingKeysGetDefaults() throws {
		let s = try JSONDecoder().decode(Settings.self, from: Data(#"{"name":"TV","port":9000}"#.utf8))
		XCTAssertTrue(s.name == "TV")
		XCTAssertTrue(s.port == 9000)
		XCTAssertTrue(s.libraries.isEmpty)
		XCTAssertTrue(!s.autoNextEpisode)
	}

	func testMissingFileGivesDefaults() throws {
		let s = try SettingsStore.load(from: URL(filePath: "/nonexistent/settings.json"))
		XCTAssertTrue(s.port == 8200)
	}

	/// The 1.0 release kept the password hash in settings.json; it is read once for the Keychain and never written again.
	func testPasswordHashIsReadButNotWritten() throws {
		let old = try JSONDecoder().decode(Settings.self, from: Data(#"{"remote":{"enabled":true,"passwordHash":"pbkdf2-sha256$1$a$b"}}"#.utf8))
		XCTAssertEqual(old.remote.passwordHash, "pbkdf2-sha256$1$a$b")
		let written = String(decoding: try JSONEncoder().encode(old), as: UTF8.self)
		XCTAssertFalse(written.contains("pbkdf2"))
		XCTAssertTrue(written.contains("enabled"))
	}

	func testLegacyDataIsCopiedOnce() throws {
		let dir = FileManager.default.temporaryDirectory.appending(path: "minordlna-\(UUID())")
		defer { try? FileManager.default.removeItem(at: dir) }
		let old = dir.appending(path: "old"), new = dir.appending(path: "new")
		try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
		try Data("{}".utf8).write(to: old.appending(path: "settings.json"))
		XCTAssertTrue(AppPaths.migrateLegacyData(from: old, to: new))
		XCTAssertTrue(FileManager.default.fileExists(atPath: new.appending(path: "settings.json").path))
		try Data("changed".utf8).write(to: new.appending(path: "settings.json"))
		XCTAssertFalse(AppPaths.migrateLegacyData(from: old, to: new)) // never over data that is already there
		XCTAssertEqual(try String(contentsOf: new.appending(path: "settings.json"), encoding: .utf8), "changed")
	}
}
