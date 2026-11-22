import Foundation
import Testing
import Synchronization
@testable import MinorCore

@Test func movieNames() {
	#expect(Names.movie("Film.Name.2019.1080p.BluRay.x264.mkv") == ("Film Name", 2019))
	#expect(Names.movie("2001 A Space Odyssey (1968).mkv") == ("2001 A Space Odyssey", 1968))
	#expect(Names.movie("Pelíšky.CZ.720p.mkv") == ("Pelíšky", 0))
}

@Test func episodeNames() {
	#expect(Names.episode("Přátelé/Přátelé.S02E05.Ten.1080p.mkv") == .init(show: "Přátelé", season: 2, episode: 5, title: "Ten"))
	#expect(Names.episode("Show/Season 1/S01E03.mkv") == .init(show: "Show", season: 1, episode: 3, title: ""))
	#expect(Names.episode("Show 3x07 Konec.avi") == .init(show: "Show", season: 3, episode: 7, title: "Konec"))
	#expect(Names.episode("Show/Série 2/04 Návrat.mkv") == .init(show: "Show", season: 2, episode: 4, title: "Návrat"))
	#expect(Names.episode("Dokument.mkv") == nil)
}

@Test func czechNaturalSort() {
	let sorted = ["Žába", "zebra", "Část 10", "Část 9", "Cesta", "Řeka", "rak"].sorted { Names.sortKey($0) < Names.sortKey($1) }
	#expect(sorted == ["Cesta", "Část 9", "Část 10", "rak", "Řeka", "zebra", "Žába"])
}

/// Shows group by series and season, a rescan keeps ids, a removed file disappears.
@Test func scanShows() throws {
	let dir = FileManager.default.temporaryDirectory.appending(path: "minordlna-\(UUID())")
	defer { try? FileManager.default.removeItem(at: dir) }
	let root = dir.appending(path: "Seriály")
	try FileManager.default.createDirectory(at: root.appending(path: "Show/Season 1"), withIntermediateDirectories: true)
	for name in ["Show/Season 1/02 Druhý.mkv", "Show/Season 1/01 První.mkv", "Show/Season 1/01 První.cs.srt", "Jiný.S01E01.mkv"] {
		try Data([0]).write(to: root.appending(path: name))
	}
	let lib = Library(name: "Seriály", type: .shows, paths: [root.path(percentEncoded: false).replacingOccurrences(of: #"/$"#, with: "", options: .regularExpression)])
	let store = try Store(url: dir.appending(path: "index.sqlite"))
	let libs = try store.syncLibraries([lib]).map { IndexedLibrary(id: $0.value, library: lib) }
	let scanner = LibraryScanner(store: store, libraries: libs) { _ in }
	scanner.scanAll(force: true)
	let cat = LibraryCatalog(db: store.reader, libraries: libs)

	let shows = try cat.children("L\(libs[0].id)/shows", start: 0, count: 0).objects
	#expect(shows.map(\.title) == ["Jiný", "Show"])
	let seasons = try cat.children(shows[1].id, start: 0, count: 0).objects
	#expect(seasons.map(\.title) == ["Série 1"])
	let eps = try cat.children(seasons[0].id, start: 0, count: 0).objects
	#expect(eps.map(\.title) == ["01. První", "02. Druhý"])
	#expect(eps[0].subtitle?.hasSuffix("01 První.cs.srt") == true)
	#expect(try cat.metadata(eps[0].id).parentID == "D" + String(try #require(store.reader.one("SELECT id FROM dir WHERE rel = 'Show/Season 1'") { $0.int64(0) })))
	#expect(store.updateID() == 1)

	try FileManager.default.removeItem(at: root.appending(path: "Jiný.S01E01.mkv"))
	scanner.scanAll(force: true)
	#expect(try cat.children("L\(libs[0].id)/shows", start: 0, count: 0).objects.map(\.title) == ["Show"])
	#expect(try cat.children(seasons[0].id, start: 0, count: 0).objects.map(\.id) == eps.map(\.id))
	#expect(store.updateID() == 2)
}

/// FSEvents reports a new file in a library; hidden files do not count.
@Test func folderWatcher() async throws {
	let dir = FileManager.default.temporaryDirectory.appending(path: "minordlna-\(UUID())")
	try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
	defer { try? FileManager.default.removeItem(at: dir) }
	let root = FolderWatcher.realPath(dir.path(percentEncoded: false))
	let roots = [(root: root, id: Int64(7)), (root: root + "-jiný", id: Int64(8))]
	#expect(FolderWatcher.libraries(for: [root + "/.DS_Store", root + "/Film/._a.mkv"], roots: roots).isEmpty)

	let seen = Mutex<Set<Int64>>([])
	let watcher = FolderWatcher(paths: [root], latency: 0.1) { paths in
		seen.withLock { $0.formUnion(FolderWatcher.libraries(for: paths, roots: roots)) }
	}
	#expect(watcher != nil)
	try await Task.sleep(for: .milliseconds(300))
	try Data([0]).write(to: dir.appending(path: "Film.mkv"))
	for _ in 0..<50 where seen.withLock({ $0.isEmpty }) { try await Task.sleep(for: .milliseconds(100)) }
	#expect(seen.withLock { $0 } == [7])
	withExtendedLifetime(watcher) {}
}
