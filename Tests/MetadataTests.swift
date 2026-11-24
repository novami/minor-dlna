import Foundation
import XCTest
@testable import MinorDLNA

final class MetadataTests: XCTestCase {
	func testChooseMatch() {
		let cands = [
			MetaCandidate(id: "Q1", title: "Červená Karkulka", description: "", year: 1962),
			MetaCandidate(id: "Q2", title: "Červená Karkulka", description: "", year: 2011),
			MetaCandidate(id: "Q3", title: "V zajetí démonů 3: Na Ďáblův příkaz", description: "", year: 2021),
		]
		XCTAssertTrue(TitleMatch.choose("Cervena Karkulka", year: 2011, cands)?.id == "Q2")
		XCTAssertTrue(TitleMatch.choose("Červená Karkulka", year: nil, cands) == nil) // two films of that name, no year: unsure
		XCTAssertTrue(TitleMatch.choose("Červená Karkulka", year: 1990, cands) == nil)
		XCTAssertTrue(TitleMatch.choose("v zajeti demonu 3", year: nil, cands)?.id == "Q3")
		XCTAssertTrue(TitleMatch.searchTitles("Film - Režisérská verze") == ["Film - Režisérská verze", "Film"])
	}

	func testWikidataEntity() throws {
		let json = #"""
		{"labels": {"en": {"value": "Cosy Dens"}, "cs": {"value": "Pelíšky"}},
		 "claims": {
		  "P31": [{"rank": "normal", "mainsnak": {"datavalue": {"value": {"id": "Q11424"}}}}],
		  "P577": [{"rank": "normal", "mainsnak": {"datavalue": {"value": {"time": "+1999-03-11T00:00:00Z"}}}},
		           {"rank": "deprecated", "mainsnak": {"datavalue": {"value": {"time": "+1990-01-01T00:00:00Z"}}}}],
		  "P2047": [{"rank": "normal", "mainsnak": {"datavalue": {"value": {"amount": "+116", "unit": "http://www.wikidata.org/entity/Q7727"}}}}]}}
		"""#
		let e = WikiEntity(json: try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]))
		XCTAssertTrue(e.label() == "Pelíšky" && e.year == 1999 && e.runtime == 116)
		XCTAssertTrue(e.is(.movies) && !e.is(.shows))
	}

	func testCatalogUsesMetadata() throws {
		let dir = FileManager.default.temporaryDirectory.appending(path: "minordlna-\(UUID())")
		defer { try? FileManager.default.removeItem(at: dir) }
		let root = dir.appending(path: "Filmy")
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
		try Data([0]).write(to: root.appending(path: "Cosy Dens (1999).mkv"))
		try Data([0]).write(to: root.appending(path: "Zeta (2001).mkv"))
		let lib = Library(name: "Filmy", type: .movies, paths: [root.path(percentEncoded: false).replacingOccurrences(of: #"/$"#, with: "", options: .regularExpression)])
		let store = try Store(url: dir.appending(path: "index.sqlite"))
		let libs = try store.syncLibraries([lib]).map { IndexedLibrary(id: $0.value, library: lib) }
		LibraryScanner(store: store, libraries: libs) { _ in }.scanAll(force: true)
		let meta = MetadataService(store: store, dir: dir.appending(path: "posters")) {}
		try meta.sync()
		XCTAssertTrue(try meta.entries().map(\.fileTitle).sorted() == ["Cosy Dens", "Zeta"])
		_ = try store.writer.run("""
			UPDATE title_match SET status = 1, title = 'Pelíšky', sort_title = ?, year = 1999, overview = 'Vánoce 1967.', poster = 1
			WHERE query = 'Cosy Dens|1999'
			""", Names.sortKey("Pelíšky"))

		let cat = LibraryCatalog(db: store.reader, libraries: libs)
		let all = try cat.children("L\(libs[0].id)/all", start: 0, count: 0).objects
		XCTAssertTrue(all.map(\.title) == ["Pelíšky (1999)", "Zeta (2001)"])
		let didl = DIDL.render(all, baseURL: "http://h:1")
		XCTAssertTrue(didl.contains("<dc:description>Vánoce 1967.</dc:description>"))
		XCTAssertTrue(didl.contains("/poster/"))

		// The poster file is gone (cache cleared): the title is looked up again and the TV gets no dead link meanwhile.
		try meta.refetchMissingPosters()
		XCTAssertTrue(try store.reader.one("SELECT poster, checked_at FROM title_match WHERE query = 'Cosy Dens|1999'") { [$0.int(0), $0.int(1)] } == [0, 0])
		XCTAssertTrue(!DIDL.render(try cat.children("L\(libs[0].id)/all", start: 0, count: 0).objects, baseURL: "http://h:1").contains("/poster/"))
	}
}

/// A matched movie and show show their Czech title, poster and overview on the TV.
