import Foundation
import Testing
@testable import MinorCore

@Test func roundTrip() throws {
	let url = FileManager.default.temporaryDirectory.appending(path: "minordlna-\(UUID())/settings.json")
	defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
	var s = Settings(name: "Obývák", port: 8300)
	s.libraries = [Library(name: "Filmy", type: .movies, paths: ["/Volumes/Data/Filmy"])]
	try SettingsStore.save(s, to: url)
	#expect(try SettingsStore.load(from: url) == s)
}

@Test func missingKeysGetDefaults() throws {
	let s = try JSONDecoder().decode(Settings.self, from: Data(#"{"name":"TV","port":9000}"#.utf8))
	#expect(s.name == "TV")
	#expect(s.port == 9000)
	#expect(s.libraries.isEmpty)
	#expect(s.autoCheck)
	#expect(s.autoUpdate)
}

@Test func missingFileGivesDefaults() throws {
	let s = try SettingsStore.load(from: URL(filePath: "/nonexistent/settings.json"))
	#expect(s.port == 8200)
}

@Test func oldSettingsKeepAutoUpdateOff() throws {
	let s = try JSONDecoder().decode(Settings.self, from: Data(#"{"autoUpdate":false}"#.utf8))
	#expect(!s.autoUpdate)
	#expect(s.autoCheck)
}
