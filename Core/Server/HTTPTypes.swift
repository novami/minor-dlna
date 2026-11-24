import Foundation
import Synchronization

nonisolated struct HTTPMethod: Hashable, Sendable {
	let rawValue: String
	init(_ s: String) { rawValue = s.uppercased() }

	static let get = HTTPMethod("GET")
	static let head = HTTPMethod("HEAD")
	static let post = HTTPMethod("POST")
	static let subscribe = HTTPMethod("SUBSCRIBE")
	static let unsubscribe = HTTPMethod("UNSUBSCRIBE")
}

nonisolated struct HTTPStatus: Hashable, Sendable {
	let code: Int
	let reason: String

	static let ok = HTTPStatus(code: 200, reason: "OK")
	static let partialContent = HTTPStatus(code: 206, reason: "Partial Content")
	static let found = HTTPStatus(code: 302, reason: "Found")
	static let badRequest = HTTPStatus(code: 400, reason: "Bad Request")
	static let unauthorized = HTTPStatus(code: 401, reason: "Unauthorized")
	static let forbidden = HTTPStatus(code: 403, reason: "Forbidden")
	static let notFound = HTTPStatus(code: 404, reason: "Not Found")
	static let methodNotAllowed = HTTPStatus(code: 405, reason: "Method Not Allowed")
	static let requestTimeout = HTTPStatus(code: 408, reason: "Request Timeout")
	static let lengthRequired = HTTPStatus(code: 411, reason: "Length Required")
	static let preconditionFailed = HTTPStatus(code: 412, reason: "Precondition Failed")
	static let payloadTooLarge = HTTPStatus(code: 413, reason: "Content Too Large")
	static let uriTooLong = HTTPStatus(code: 414, reason: "URI Too Long")
	static let rangeNotSatisfiable = HTTPStatus(code: 416, reason: "Range Not Satisfiable")
	static let unprocessableContent = HTTPStatus(code: 422, reason: "Unprocessable Content")
	static let tooManyRequests = HTTPStatus(code: 429, reason: "Too Many Requests")
	static let headerFieldsTooLarge = HTTPStatus(code: 431, reason: "Request Header Fields Too Large")
	static let internalServerError = HTTPStatus(code: 500, reason: "Internal Server Error")
	static let notImplemented = HTTPStatus(code: 501, reason: "Not Implemented")
	static let serviceUnavailable = HTTPStatus(code: 503, reason: "Service Unavailable")
}

/// Header name compared without case; the spelling given is kept, because some TVs match DLNA headers case-sensitively.
nonisolated struct HTTPHeaderName: Hashable, Sendable, ExpressibleByStringLiteral {
	let name: String
	init(_ name: String) { self.name = name }
	init(stringLiteral value: String) { name = value }

	static func == (a: Self, b: Self) -> Bool { a.name.caseInsensitiveCompare(b.name) == .orderedSame }
	func hash(into h: inout Hasher) { h.combine(name.lowercased()) }

	static let contentType: Self = "Content-Type"
	static let contentLength: Self = "Content-Length"
	static let acceptRanges: Self = "Accept-Ranges"
	static let contentRange: Self = "Content-Range"
	static let range: Self = "Range"
	static let lastModified: Self = "Last-Modified"
	static let cacheControl: Self = "Cache-Control"
	static let location: Self = "Location"
	static let setCookie: Self = "Set-Cookie"
	static let cookie: Self = "Cookie"
	static let userAgent: Self = "User-Agent"
	static let host: Self = "Host"
	static let connection: Self = "Connection"
	static let transferMode: Self = "transferMode.dlna.org"
	static let contentFeatures: Self = "contentFeatures.dlna.org"
	static let getContentFeatures: Self = "getcontentFeatures.dlna.org"
	static let soapAction: Self = "SOAPAction"
	static let sid: Self = "SID"
	static let nt: Self = "NT"
	static let callback: Self = "CALLBACK"
	static let timeout: Self = "TIMEOUT"
	static let ext: Self = "EXT"
	static let timeSeekRange: Self = "TimeSeekRange.dlna.org"
	static let captionInfo: Self = "CaptionInfo.sec"
	static let avClientInfo: Self = "X-AV-Client-Info"
}

nonisolated struct HTTPHeaders: Sendable, ExpressibleByDictionaryLiteral {
	private(set) var fields: [(name: HTTPHeaderName, value: String)] = []

	init() {}

	init(dictionaryLiteral elements: (HTTPHeaderName, String)...) {
		for (k, v) in elements { fields.append((k, v)) }
	}

	subscript(_ name: HTTPHeaderName) -> String? {
		get { fields.first { $0.name == name }?.value }
		set {
			fields.removeAll { $0.name == name }
			if let newValue { fields.append((name, newValue)) }
		}
	}

	subscript(values name: HTTPHeaderName) -> [String] { fields.filter { $0.name == name }.map(\.value) }

	/// Adds a field without replacing an earlier one with the same name.
	mutating func append(_ name: HTTPHeaderName, _ value: String) { fields.append((name, value)) }
}

nonisolated struct HTTPRequest: Sendable {
	var method: HTTPMethod
	/// Percent-decoded path without the query.
	var path: String
	var query: [String: String] = [:]
	var headers = HTTPHeaders()
	var body = Data()
	/// Peer address without an interface scope.
	var remoteIP = ""
	/// Filled by the router from `:name` segments.
	var parameters: [String: String] = [:]

	/// The Host header: how the client addressed this server.
	var authority: String? { headers[.host] }
}

/// What a streamed response body writes to.
nonisolated final class BodyWriter: Sendable {
	private let sink: @Sendable (Data) async throws -> Void
	init(_ sink: @escaping @Sendable (Data) async throws -> Void) { self.sink = sink }
	func write(_ data: Data) async throws { if !data.isEmpty { try await sink(data) } }
}

nonisolated enum HTTPBody: Sendable {
	case empty
	case data(Data)
	/// Bytes offset ..< offset + length of a file, read in chunks.
	case file(path: String, offset: Int64, length: Int64)
	/// Produced while the client reads; sent chunked.
	case stream(@Sendable (BodyWriter) async throws -> Void)
}

nonisolated struct HTTPResponse: Sendable {
	var status: HTTPStatus
	var headers = HTTPHeaders()
	var body = HTTPBody.empty

	init(status: HTTPStatus, headers: HTTPHeaders = [:], body: HTTPBody = .empty) {
		self.status = status
		self.headers = headers
		self.body = body
	}

	static func text(_ s: String, type: String = "text/plain; charset=utf-8", status: HTTPStatus = .ok, headers: HTTPHeaders = [:]) -> Self {
		var h = headers
		h[.contentType] = type
		return Self(status: status, headers: h, body: .data(Data(s.utf8)))
	}
}

/// Matches method and path ("/media/:token"); the first registered route that fits wins.
nonisolated final class Router: Sendable {
	typealias Handler = @Sendable (HTTPRequest) async throws -> HTTPResponse
	private struct Route {
		var method: HTTPMethod
		var parts: [Substring]
		var handler: Handler
	}
	private let routes = Mutex<[Route]>([])

	func on(_ method: HTTPMethod, _ pattern: String, _ handler: @escaping Handler) {
		routes.withLock { $0.append(Route(method: method, parts: pattern.split(separator: "/"), handler: handler)) }
	}

	func get(_ p: String, _ h: @escaping Handler) { on(.get, p, h) }
	func head(_ p: String, _ h: @escaping Handler) { on(.head, p, h) }
	func post(_ p: String, _ h: @escaping Handler) { on(.post, p, h) }

	func handle(_ request: HTTPRequest) async -> HTTPResponse {
		let parts = request.path.split(separator: "/")
		var pathMatched = false
		let all = routes.withLock { $0 }
		for r in all {
			guard r.parts.count == parts.count else { continue }
			var params: [String: String] = [:]
			var ok = true
			for (pattern, part) in zip(r.parts, parts) {
				if pattern.hasPrefix(":") { params[String(pattern.dropFirst())] = String(part) } else if pattern != part { ok = false; break }
			}
			guard ok else { continue }
			pathMatched = true
			guard r.method == request.method else { continue }
			var req = request
			req.parameters = params
			do {
				return try await r.handler(req)
			} catch {
				AppLog.server.error("handler failed: \(error, privacy: .public)")
				return HTTPResponse(status: .internalServerError)
			}
		}
		return HTTPResponse(status: pathMatched ? .methodNotAllowed : .notFound)
	}
}
