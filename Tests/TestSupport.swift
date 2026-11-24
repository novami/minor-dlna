import Foundation
import Synchronization
import XCTest
@testable import MinorDLNA

/// A router answer with its body read out.
struct Reply {
	var response: HTTPResponse
	var body: Data
	var status: HTTPStatus { response.status }
	var headers: HTTPHeaders { response.headers }
	var text: String { String(decoding: body, as: UTF8.self) }
}

/// Calls a router in-process; the request goes through the real head parser.
func call(_ router: Router, _ method: HTTPMethod = .get, _ target: String, headers: HTTPHeaders = [:], body: String = "",
          ip: String = "127.0.0.1", host: String = "localhost:8200") async -> Reply {
	var raw = "\(method.rawValue) \(target) HTTP/1.1\r\nHost: \(host)\r\n"
	for f in headers.fields { raw += "\(f.name.name): \(f.value)\r\n" }
	raw += "Content-Length: \(body.utf8.count)\r\n\r\n"
	let head: HTTPParser.Head
	switch HTTPParser.parseHead(Data(raw.utf8)) {
	case let .head(h, _): head = h
	case let .invalid(status): return Reply(response: HTTPResponse(status: status), body: Data())
	case .needMore: return Reply(response: HTTPResponse(status: .badRequest), body: Data())
	}
	var req = HTTPRequest(method: head.method, path: head.path, query: head.query, headers: head.headers, remoteIP: ip)
	req.body = Data(body.utf8)
	let response = await router.handle(req)
	return Reply(response: response, body: await read(response.body))
}

func read(_ body: HTTPBody) async -> Data {
	switch body {
	case .empty: return Data()
	case let .data(d): return d
	case let .file(path, offset, length):
		guard let fh = FileHandle(forReadingAtPath: path) else { return Data() }
		defer { try? fh.close() }
		try? fh.seek(toOffset: UInt64(offset))
		return (try? fh.read(upToCount: Int(length))) ?? Data()
	case let .stream(produce):
		let out = Mutex(Data())
		try? await produce(BodyWriter { d in out.withLock { $0.append(d) } })
		return out.withLock { $0 }
	}
}

func soapBrowse(_ id: String) -> String {
	#"<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><u:Browse xmlns:u="urn:schemas-upnp-org:service:ContentDirectory:1"><ObjectID>\#(id)</ObjectID><BrowseFlag>BrowseDirectChildren</BrowseFlag><StartingIndex>0</StartingIndex><RequestedCount>10</RequestedCount></u:Browse></s:Body></s:Envelope>"#
}

let browseAction: HTTPHeaders = [HTTPHeaderName("SOAPAction"): #""urn:schemas-upnp-org:service:ContentDirectory:1#Browse""#]

/// A port nobody listens on right now.
func freePort() -> Int {
	let fd = socket(AF_INET, SOCK_STREAM, 0)
	defer { close(fd) }
	var addr = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET), sin_port: 0,
	                       sin_addr: in_addr(s_addr: INADDR_LOOPBACK.bigEndian), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
	_ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
	var len = socklen_t(MemoryLayout<sockaddr_in>.size)
	_ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
	return Int(UInt16(bigEndian: addr.sin_port))
}

/// Serves a router on a free local port until `stop` is called.
func serve(_ router: Router) async throws -> (port: Int, stop: @Sendable () -> Void) {
	let port = freePort()
	let ready = AsyncStream<Void>.makeStream()
	let server = HTTPServer(port: port, serverName: "test") { await router.handle($0) }
	let task = Task { try? await server.run { ready.continuation.yield() } }
	for await _ in ready.stream { break }
	return (port, { task.cancel() })
}
