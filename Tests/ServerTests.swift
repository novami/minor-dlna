import Foundation
import XCTest
@testable import MinorDLNA

final class ServerTests: XCTestCase {
	private func head(_ raw: String) -> HTTPParser.Result { HTTPParser.parseHead(Data(raw.utf8)) }

	func testParsesRequestHead() throws {
		let request = "GET /a%20b/c?q=x+y&n=%C5%A1 HTTP/1.1\r\nHost: tv:8200\r\nRange: bytes=0-9\r\n\r\n"
		guard case let .head(h, consumed) = head(request + "BODY") else { return XCTFail("not parsed") }
		XCTAssertEqual(h.path, "/a b/c")
		XCTAssertEqual(h.query["q"], "x y")
		XCTAssertEqual(h.query["n"], "š")
		XCTAssertEqual(h.headers[.range], "bytes=0-9")
		XCTAssertEqual(consumed, request.utf8.count)
		XCTAssertFalse(h.close)
	}

	func testRejectsBadAndOversizedRequests() {
		func status(_ r: HTTPParser.Result) -> Int? { if case let .invalid(s) = r { s.code } else { nil } }
		XCTAssertEqual(status(head("GET / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n")), 501)
		XCTAssertEqual(status(head("GET / HTTP/1.1\r\nContent-Length: 99999999\r\n\r\n")), 413)
		XCTAssertEqual(status(head("GARBAGE\r\n\r\n")), 400)
		XCTAssertEqual(status(head("GET /x HTTP/1.1\r\n" + String(repeating: "A: b\r\n", count: 100) + "\r\n")), 431)
		XCTAssertEqual(status(head("GET /" + String(repeating: "a", count: 5000) + " HTTP/1.1\r\n\r\n")), 414)
		guard case .needMore = head("GET / HTTP/1.1\r\nHost: x\r\n") else { return XCTFail("should wait for the rest") }
	}

	func testTraversalIsRefusedInAnyEncoding() {
		for target in ["/media/../etc/passwd", "/media/%2e%2e/etc/passwd", "/media/%2E%2E%2Fetc", "/media/..\\x"] {
			guard case let .invalid(s) = head("GET \(target) HTTP/1.1\r\n\r\n") else {
				// "%2e%2e%2f" decodes to "../" inside one segment; it is not a path that exists either way.
				if case let .head(h, _) = head("GET \(target) HTTP/1.1\r\n\r\n") { XCTAssertTrue(h.path.contains("/") ) }
				continue
			}
			XCTAssertEqual(s.code, 403, target)
		}
	}

	func testPathGuardKeepsToLibrary() throws {
		let dir = FileManager.default.temporaryDirectory.appending(path: "minordlna-\(UUID())")
		defer { try? FileManager.default.removeItem(at: dir) }
		let lib = dir.appending(path: "Filmy"), other = dir.appending(path: "Tajne")
		try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
		try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
		try Data([1]).write(to: lib.appending(path: "a.mkv"))
		try Data([1]).write(to: other.appending(path: "b.mkv"))
		try FileManager.default.createSymbolicLink(at: lib.appending(path: "link.mkv"), withDestinationURL: other.appending(path: "b.mkv"))
		let guardian = PathGuard(roots: [lib.path])
		XCTAssertNotNil(guardian.allowed(lib.appending(path: "a.mkv").path))
		XCTAssertNil(guardian.allowed(other.appending(path: "b.mkv").path))
		XCTAssertNil(guardian.allowed(lib.appending(path: "../Tajne/b.mkv").path))
		XCTAssertNil(guardian.allowed(lib.appending(path: "link.mkv").path)) // a link out of the library
		XCTAssertNil(guardian.allowed(lib.path + "-evil/a.mkv")) // same prefix, other folder
	}

	/// The real listener: Range, keep-alive, traversal and the size limit over a socket.
	func testServesOverTheNetwork() async throws {
		let dir = FileManager.default.temporaryDirectory.appending(path: "minordlna-\(UUID())")
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: dir) }
		let file = dir.appending(path: "f.bin")
		try Data((0..<200).map { UInt8($0) }).write(to: file)
		let router = Router()
		router.get("/f") { req in
			let size: Int64 = 200
			guard let header = req.headers[.range] else { return HTTPResponse(status: .ok, body: .file(path: file.path, offset: 0, length: size)) }
			guard let r = ByteRange.parse(header, size: size) else { return HTTPResponse(status: .rangeNotSatisfiable) }
			return HTTPResponse(status: .partialContent, headers: [.contentRange: "bytes \(r.lowerBound)-\(r.upperBound)/\(size)"],
			                    body: .file(path: file.path, offset: r.lowerBound, length: r.upperBound - r.lowerBound + 1))
		}
		router.get("/s") { _ in HTTPResponse(status: .ok, body: .stream { w in
			for i in 0..<3 { try await w.write(Data("part\(i);".utf8)) }
		}) }
		let (port, stop) = try await serve(router)
		defer { stop() }
		let base = "http://127.0.0.1:\(port)"
		let session = URLSession(configuration: .ephemeral)

		var req = URLRequest(url: URL(string: base + "/f")!)
		req.setValue("bytes=10-19", forHTTPHeaderField: "Range")
		let (part, res) = try await session.data(for: req)
		XCTAssertEqual((res as? HTTPURLResponse)?.statusCode, 206)
		XCTAssertEqual(Array(part), Array(10..<20))

		req.setValue("bytes=-5", forHTTPHeaderField: "Range")
		let (suffix, _) = try await session.data(for: req)
		XCTAssertEqual(Array(suffix), Array(195..<200))
		req.setValue("bytes=500-", forHTTPHeaderField: "Range")
		let (_, unsatisfiable) = try await session.data(for: req)
		XCTAssertEqual((unsatisfiable as? HTTPURLResponse)?.statusCode, 416)

		let (chunked, _) = try await session.data(from: URL(string: base + "/s")!)
		XCTAssertEqual(String(decoding: chunked, as: UTF8.self), "part0;part1;part2;")
		let (_, missing) = try await session.data(from: URL(string: base + "/nothing")!)
		XCTAssertEqual((missing as? HTTPURLResponse)?.statusCode, 404)
		// Raw path with "..": refused before any route sees it.
		let (_, evil) = try await session.data(from: URL(string: base + "/f/%2e%2e/%2e%2e/etc/passwd")!)
		XCTAssertTrue([403, 404].contains((evil as? HTTPURLResponse)?.statusCode ?? 0))
	}

	/// Many SOAP calls over one keep-alive connection, as a TV poller makes them.
	func testManyRequestsOnOneConnection() async throws {
		let router = Router()
		router.post("/soap") { req in HTTPResponse.text("<r>\(req.body.count)</r>", type: "text/xml") }
		let (port, stop) = try await serve(router)
		defer { stop() }
		let session = URLSession(configuration: .ephemeral)
		var request = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/soap")))
		request.httpMethod = "POST"
		request.httpBody = Data(repeating: 65, count: 1500)
		for i in 0..<300 {
			let (data, res) = try await session.data(for: request)
			XCTAssertEqual((res as? HTTPURLResponse)?.statusCode, 200, "request \(i)")
			XCTAssertEqual(String(decoding: data, as: UTF8.self), "<r>1500</r>")
		}
	}

	func testSSDPMessages() throws {
		let s = SSDPService(uuid: "abc", port: 8200, serverHeader: "test", services: [Descriptions.cdsType])
		XCTAssertEqual(s.matches(searchTarget: "ssdp:all").count, 4)
		XCTAssertEqual(s.matches(searchTarget: Descriptions.cdsType).map(\.usn), ["uuid:abc::\(Descriptions.cdsType)"])
		XCTAssertTrue(s.matches(searchTarget: "urn:other").isEmpty)
		let search = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: ssdp:all\r\n\r\n"
		let parsed = try XCTUnwrap(SSDPService.parseSearch(search))
		XCTAssertEqual(parsed.st, "ssdp:all")
		XCTAssertEqual(parsed.mx, 2)
		XCTAssertNil(SSDPService.parseSearch("NOTIFY * HTTP/1.1\r\n\r\n"))
		let reply = SSDPService.searchReply(target: s.targets[0], location: "http://10.0.0.2:8200/description.xml", server: "test")
		XCTAssertTrue(reply.hasPrefix("HTTP/1.1 200 OK\r\n") && reply.contains("LOCATION: http://10.0.0.2:8200/description.xml\r\n") && reply.hasSuffix("\r\n\r\n"))
		let found = try XCTUnwrap(Discovery.location(reply))
		XCTAssertEqual(found, "http://10.0.0.2:8200/description.xml")
	}
}
