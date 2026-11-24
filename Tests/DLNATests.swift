import Foundation
import XCTest
@testable import MinorDLNA

final class DLNATests: XCTestCase {
	func testByteRanges() {
		XCTAssertTrue(ByteRange.parse("bytes=0-99", size: 1000) == 0...99)
		XCTAssertTrue(ByteRange.parse("bytes=900-", size: 1000) == 900...999)
		XCTAssertTrue(ByteRange.parse("bytes=-100", size: 1000) == 900...999)
		XCTAssertTrue(ByteRange.parse("bytes=500-5000", size: 1000) == 500...999)
		XCTAssertTrue(ByteRange.parse("bytes=1000-", size: 1000) == nil)
		XCTAssertTrue(ByteRange.parse("bytes=9-3", size: 1000) == nil)
	}

	func testSoapParse() {
		let body = #"""
		<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>
		<u:Browse xmlns:u="urn:schemas-upnp-org:service:ContentDirectory:1"><ObjectID>0</ObjectID><BrowseFlag>BrowseDirectChildren</BrowseFlag></u:Browse>
		</s:Body></s:Envelope>
		"""#
		let call = SOAP.parse(Data(body.utf8), soapAction: #""urn:schemas-upnp-org:service:ContentDirectory:1#Browse""#)
		XCTAssertTrue(call == SOAP.Call(action: "Browse", args: ["ObjectID": "0", "BrowseFlag": "BrowseDirectChildren"]))
	}

	func testBrowseAndStream() async throws {
		let dir = FileManager.default.temporaryDirectory.appending(path: "minordlna-\(UUID())")
		try FileManager.default.createDirectory(at: dir.appending(path: "Sub"), withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: dir) }
		try Data((0..<100).map { UInt8($0) }).write(to: dir.appending(path: "Film & Co.mkv"))
		try Data().write(to: dir.appending(path: "notes.txt"))
		try Data([1]).write(to: dir.appending(path: "Sub/x.mp4"))

		let lib = Library(name: "Filmy", type: .videos, paths: [dir.path(percentEncoded: false).replacingOccurrences(of: #"/$"#, with: "", options: .regularExpression)])
		var settings = Settings(name: "Test")
		settings.libraries = [lib]
		let store = try Store(url: dir.appending(path: "index.sqlite"))
		let libs = try store.syncLibraries([lib]).map { IndexedLibrary(id: $0.value, library: lib) }
		LibraryScanner(store: store, libraries: libs) { _ in }.scanAll(force: true)
		let routes = Routes(config: ServerConfig(settings: settings, version: "test", iconURL: nil), store: store, libraries: libs)
		let router = routes.router()

		let libID = "L\(libs[0].id)/folders"
		let browse = await call(router, .post, "/cds/control", headers: browseAction, body: soapBrowse(libID))
		XCTAssertEqual(browse.status, .ok)
		let didl = browse.text
		XCTAssertTrue(didl.contains("&lt;dc:title&gt;Sub&lt;/dc:title&gt;"))
		XCTAssertTrue(didl.contains("Film &amp;amp; Co"))
		XCTAssertTrue(!didl.contains("notes"))
		XCTAssertTrue(didl.contains("&lt;TotalMatches&gt;") == false && didl.contains("<TotalMatches>2</TotalMatches>"))

		let item = try XCTUnwrap(didl.firstMatch(of: /\/media\/(\d+)\.mkv/)?.1)
		let part = await call(router, .get, "/media/\(item).mkv", headers: [.range: "bytes=10-19", .getContentFeatures: "1"])
		XCTAssertEqual(part.status, .partialContent)
		XCTAssertEqual(part.headers[.contentRange], "bytes 10-19/100")
		XCTAssertEqual(Array(part.body), Array(10..<20))
		XCTAssertTrue(part.headers[.contentFeatures]?.hasPrefix("DLNA.ORG_OP=01") == true)
		// An unsatisfiable range is 416; a crafted id is 404.
		let bad = await call(router, .get, "/media/\(item).mkv", headers: [.range: "bytes=500-"])
		XCTAssertEqual(bad.status, .rangeNotSatisfiable)
		let traversal = await call(router, .get, "/media/..%2F..%2Fetc%2Fpasswd")
		XCTAssertEqual(traversal.status, .forbidden)
		let unknown = await call(router, .get, "/media/999999.mkv")
		XCTAssertEqual(unknown.status, .notFound)
	}

	/// A port the system has just reported free (a random fixed range can collide with ephemeral ports on CI).
	private static func freePort() -> Int {
		let fd = socket(AF_INET, SOCK_STREAM, 0)
		defer { close(fd) }
		var addr = sockaddr_in()
		addr.sin_family = sa_family_t(AF_INET)
		addr.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
		var len = socklen_t(MemoryLayout<sockaddr_in>.size)
		withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = Darwin.bind(fd, $0, len); _ = getsockname(fd, $0, &len) } }
		return Int(UInt16(bigEndian: addr.sin_port))
	}

	func testRestartReusesPort() async throws {
		let dir = FileManager.default.temporaryDirectory.appending(path: "minordlna-\(UUID())")
		defer { try? FileManager.default.removeItem(at: dir) }
		let a = MediaServer(), b = MediaServer()
		func next(_ s: MediaServer, where ok: (ServerState) -> Bool) async -> ServerState? {
			for await st in s.states where ok(st) { return st }
			return nil
		}
		let isFinal = { (s: ServerState) in if case .starting = s { false } else if case .stopped = s { false } else { true } }
		let isRunning = { (s: ServerState?) in if case .running = s { true } else { false } }
		// Another test process can take the freed port before the server does, so try a few ports.
		var port = 0, config: ServerConfig?
		for _ in 0..<5 {
			port = Self.freePort()
			let c = ServerConfig(settings: Settings(name: "Test", port: port), version: "test", iconURL: nil, databaseURL: dir.appending(path: "index.sqlite"))
			await a.start(c)
			if isRunning(await next(a, where: isFinal)) { config = c; break }
		}
		let running = try XCTUnwrap(config, "no free port found")
		await a.start(running)
		do { let st = await next(a, where: isFinal); XCTAssertTrue(isRunning(st), "restart on port \(port): \(String(describing: st))") }
		await b.start(running)
		do { let st = await next(b, where: isFinal); XCTAssertEqual(st, .failed("Port \(port) už používá jiná aplikace.")) }
		await a.stop()
		await b.stop()
	}

	func testWebAccess() async throws {
		let dir = FileManager.default.temporaryDirectory.appending(path: "minordlna-\(UUID())")
		defer { try? FileManager.default.removeItem(at: dir) }
		let routes = Routes(config: ServerConfig(settings: Settings(name: "Test"), version: "test", iconURL: nil),
		                    store: try Store(url: dir.appending(path: "index.sqlite")), libraries: [])
		let router = routes.router()
		let state = await call(router, .get, "/api/state") // the Mac itself
		XCTAssertEqual(state.status, .ok)
		let logout = await call(router, .post, "/api/logout") // no CSRF header
		XCTAssertEqual(logout.status, .forbidden)
		let remote = await call(router, .get, "/api/state", ip: "192.168.1.5", host: "192.168.1.2:8200") // remote access is off
		XCTAssertEqual(remote.status, .forbidden)
		XCTAssertTrue(WebRoutes.isLocal(ip: "127.0.0.1", authority: "localhost:8200"))
		XCTAssertTrue(WebRoutes.isLocal(ip: "::1", authority: "[::1]:8200"))
		XCTAssertTrue(!WebRoutes.isLocal(ip: "127.0.0.1", authority: "evil.example:8200")) // DNS rebinding
		XCTAssertTrue(!WebRoutes.isLocal(ip: "192.168.1.5", authority: "localhost:8200"))
	}

	func testWebLogin() throws {
		let access = WebAccess()
		XCTAssertTrue(access.login(ip: "10.0.0.8", password: "") == .disabled)
		access.configure(RemoteSettings(enabled: true, passwordHash: WebPassword.hash("tajne-heslo")))
		guard case let .ok(token) = access.login(ip: "10.0.0.8", password: "tajne-heslo") else { XCTFail("login failed"); return }
		XCTAssertTrue(access.valid(token) && !access.valid("x"))
		for _ in 0..<WebAccess.maxFailures { XCTAssertTrue(access.login(ip: "10.0.0.9", password: "x") == .wrong) }
		XCTAssertTrue(access.login(ip: "10.0.0.9", password: "tajne-heslo") == .locked)
		access.configure(RemoteSettings(enabled: true, passwordHash: WebPassword.hash("jine-heslo")))
		XCTAssertTrue(!access.valid(token)) // a new password logs everybody out
	}
}
