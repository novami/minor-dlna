import Foundation
import Hummingbird
import HummingbirdTesting
import Testing
@testable import MinorCore

@Test func byteRanges() {
	#expect(ByteRange.parse("bytes=0-99", size: 1000) == 0...99)
	#expect(ByteRange.parse("bytes=900-", size: 1000) == 900...999)
	#expect(ByteRange.parse("bytes=-100", size: 1000) == 900...999)
	#expect(ByteRange.parse("bytes=500-5000", size: 1000) == 500...999)
	#expect(ByteRange.parse("bytes=1000-", size: 1000) == nil)
	#expect(ByteRange.parse("bytes=9-3", size: 1000) == nil)
}

@Test func tokensStayInsideLibraries() throws {
	let lib = Library(name: "Filmy", type: .movies, paths: ["/Volumes/Data/Filmy"])
	let cat = FolderCatalog(libraries: [lib])
	let token = FolderCatalog.token(for: "/Volumes/Data/Filmy/a.mkv")
	#expect(FolderCatalog.path(fromToken: Substring(token)) == "/Volumes/Data/Filmy/a.mkv")
	// ".." would resolve outside the root, and a sibling with the same prefix is not inside it.
	#expect(FolderCatalog.path(fromToken: Substring(FolderCatalog.token(for: "/Volumes/Data/Filmy/../x.mkv"))) == nil)
	#expect(cat.media(token: Substring(FolderCatalog.token(for: "/Volumes/Data/Filmy2/a.mkv"))) == nil)
}

@Test func soapParse() {
	let body = #"""
	<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>
	<u:Browse xmlns:u="urn:schemas-upnp-org:service:ContentDirectory:1"><ObjectID>0</ObjectID><BrowseFlag>BrowseDirectChildren</BrowseFlag></u:Browse>
	</s:Body></s:Envelope>
	"""#
	let call = SOAP.parse(Data(body.utf8), soapAction: #""urn:schemas-upnp-org:service:ContentDirectory:1#Browse""#)
	#expect(call == SOAP.Call(action: "Browse", args: ["ObjectID": "0", "BrowseFlag": "BrowseDirectChildren"]))
}

@Test func browseAndStream() async throws {
	let dir = FileManager.default.temporaryDirectory.appending(path: "minordlna-\(UUID())")
	try FileManager.default.createDirectory(at: dir.appending(path: "Sub"), withIntermediateDirectories: true)
	defer { try? FileManager.default.removeItem(at: dir) }
	try Data((0..<100).map { UInt8($0) }).write(to: dir.appending(path: "Film & Co.mkv"))
	try Data().write(to: dir.appending(path: "notes.txt"))

	let lib = Library(name: "Filmy", type: .movies, paths: [dir.path(percentEncoded: false).replacingOccurrences(of: #"/$"#, with: "", options: .regularExpression)])
	var settings = Settings(name: "Test")
	settings.libraries = [lib]
	let routes = Routes(config: ServerConfig(settings: settings, version: "test", iconURL: nil))
	let app = Application(router: routes.router())

	try await app.test(.live) { client in
		let libID = "L\(lib.id.uuidString)"
		let browse = #"<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><u:Browse xmlns:u="urn:schemas-upnp-org:service:ContentDirectory:1"><ObjectID>\#(libID)</ObjectID><BrowseFlag>BrowseDirectChildren</BrowseFlag><StartingIndex>0</StartingIndex><RequestedCount>10</RequestedCount></u:Browse></s:Body></s:Envelope>"#
		let didl = try await client.execute(uri: "/cds/control", method: .post, body: ByteBuffer(string: browse)) { res in
			#expect(res.status == .ok)
			return String(buffer: res.body)
		}
		#expect(didl.contains("&lt;dc:title&gt;Sub&lt;/dc:title&gt;"))
		#expect(didl.contains("Film &amp;amp; Co"))
		#expect(!didl.contains("notes"))
		#expect(didl.contains("&lt;TotalMatches&gt;") == false && didl.contains("<TotalMatches>2</TotalMatches>"))

		let token = FolderCatalog.token(for: lib.paths[0] + "/Film & Co.mkv")
		try await client.execute(uri: "/media/\(token).mkv", method: .get,
		                         headers: [.range: "bytes=10-19", .getContentFeatures: "1"]) { res in
			#expect(res.status == .partialContent)
			#expect(res.headers[.contentRange] == "bytes 10-19/100")
			#expect(Array(res.body.readableBytesView) == Array(10..<20))
			#expect(res.headers[.contentFeatures]?.hasPrefix("DLNA.ORG_OP=01") == true)
		}
	}
}

@Test func privateTmpPathsResolve() {
	let p = "/private/tmp/media/a.mkv"
	#expect(FolderCatalog.path(fromToken: Substring(FolderCatalog.token(for: p))) == p)
}

/// A restart must release the port before binding again; a second server on a busy port reports it.
@Test func restartReusesPort() async throws {
	let settings = Settings(name: "Test", port: Int.random(in: 40000...50000))
	let config = ServerConfig(settings: settings, version: "test", iconURL: nil)
	let a = MediaServer(), b = MediaServer()
	func next(_ s: MediaServer, where ok: (ServerState) -> Bool) async -> ServerState? {
		for await st in s.states where ok(st) { return st }
		return nil
	}
	let isFinal = { (s: ServerState) in if case .starting = s { false } else if case .stopped = s { false } else { true } }
	await a.start(config)
	#expect(await next(a, where: isFinal).map { if case .running = $0 { true } else { false } } == true)
	await a.start(config)
	#expect(await next(a, where: isFinal).map { if case .running = $0 { true } else { false } } == true)
	await b.start(config)
	#expect(await next(b, where: isFinal) == .failed("Port \(settings.port) už používá jiná aplikace."))
	await a.stop()
	await b.stop()
}
