import Foundation
import Network

/// HTTP/1.1 server on Network.framework: keep-alive, bounded heads and bodies, timeouts, streamed bodies.
/// Only clients on private networks are served.
nonisolated final class HTTPServer: Sendable {
	static let maxConnections = 64
	static let headTimeout: Duration = .seconds(20)
	static let idleTimeout: Duration = .seconds(60)

	let port: Int
	let serverName: String
	let handler: @Sendable (HTTPRequest) async -> HTTPResponse
	let chunkSize = 256 * 1024

	init(port: Int, serverName: String, handler: @escaping @Sendable (HTTPRequest) async -> HTTPResponse) {
		self.port = port
		self.serverName = serverName
		self.handler = handler
	}

	/// Listens until the calling task is cancelled. `onReady` fires once the port is bound.
	func run(onReady: @escaping @Sendable () -> Void) async throws {
		guard let p = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { throw HTTPServerError.invalidPort }
		let failure = FailureBox()
		let listener = try NetworkListener(using: .parameters { TCP().noDelay(true) }.localPort(p).localEndpointReuseAllowed(true))
			.newConnectionLimit(Self.maxConnections)
			.onStateUpdate { _, state in
				switch state {
				case .ready: onReady()
				case let .failed(error): failure.set(error)
				default: break
				}
			}
		do {
			try await listener.run { [self] connection in await serve(connection) }
		} catch {
			throw failure.get() ?? error
		}
		if let error = failure.get() { throw error }
	}

	// MARK: Connection

	private func serve(_ c: NetworkConnection<TCP>) async {
		let ip = Self.address(c.remoteEndpoint)
		guard AccessPolicy.allows(ip) else {
			try? await send(c, HTTPResponse(status: .forbidden), head: false, keepAlive: false, http11: true)
			return
		}
		var buffer = Data()
		var first = true
		while !Task.isCancelled {
			let head: HTTPParser.Head
			do {
				switch try await readHead(c, &buffer, timeout: first ? Self.headTimeout : Self.idleTimeout) {
				case .closed: return
				case let .invalid(status):
					try? await send(c, HTTPResponse(status: status), head: false, keepAlive: false, http11: true)
					return
				case let .head(h): head = h
				}
			} catch { return }
			first = false
			var request = HTTPRequest(method: head.method, path: head.path, query: head.query, headers: head.headers, remoteIP: ip)
			if head.contentLength > 0 {
				guard let body = try? await readBody(c, &buffer, length: head.contentLength) else { return }
				request.body = body
			}
			let response = await handler(request)
			let keep = !head.close
			do {
				try await send(c, response, head: head.method == .head, keepAlive: keep, http11: head.http11)
			} catch {
				AppLog.server.debug("client gone: \(error, privacy: .public)")
				return
			}
			if !keep { return }
		}
	}

	private enum HeadResult {
		case head(HTTPParser.Head)
		case invalid(HTTPStatus)
		case closed
	}

	private func readHead(_ c: NetworkConnection<TCP>, _ buffer: inout Data, timeout: Duration) async throws -> HeadResult {
		while true {
			switch HTTPParser.parseHead(buffer) {
			case let .head(head, consumed):
				buffer.removeFirst(consumed)
				return .head(head)
			case let .invalid(status): return .invalid(status)
			case .needMore:
				guard let chunk = try await receive(c, timeout: timeout), !chunk.isEmpty else { return .closed }
				buffer.append(chunk)
			}
		}
	}

	private func readBody(_ c: NetworkConnection<TCP>, _ buffer: inout Data, length: Int) async throws -> Data {
		while buffer.count < length {
			guard let chunk = try await receive(c, timeout: Self.headTimeout), !chunk.isEmpty else { throw HTTPServerError.closed }
			buffer.append(chunk)
		}
		let body = buffer.prefix(length)
		buffer.removeFirst(length)
		return Data(body)
	}

	/// nil on timeout.
	private func receive(_ c: NetworkConnection<TCP>, timeout: Duration) async throws -> Data? {
		try await withThrowingTaskGroup(of: Data?.self) { group in
			group.addTask { try await c.receive(atLeast: 1, atMost: 64 * 1024).content }
			group.addTask {
				try await Task.sleep(for: timeout)
				return nil
			}
			defer { group.cancelAll() }
			guard let first = try await group.next() else { return nil }
			return first
		}
	}

	// MARK: Response

	private func send(_ c: NetworkConnection<TCP>, _ response: HTTPResponse, head headOnly: Bool, keepAlive: Bool, http11: Bool) async throws {
		var headers = response.headers
		headers[.connection] = keepAlive ? "keep-alive" : "close"
		headers[HTTPHeaderName("Server")] = serverName
		headers[HTTPHeaderName("Date")] = httpDate.string(from: Date())
		let chunked: Bool
		switch response.body {
		case let .data(d):
			chunked = false
			headers[.contentLength] = String(d.count)
		case let .file(_, _, length):
			chunked = false
			headers[.contentLength] = String(length)
		case .empty:
			chunked = false
			if headers[.contentLength] == nil { headers[.contentLength] = "0" }
		case .stream:
			chunked = http11
			if http11 { headers[HTTPHeaderName("Transfer-Encoding")] = "chunked" } else { headers[.connection] = "close" }
		}
		var text = "HTTP/1.1 \(response.status.code) \(response.status.reason)\r\n"
		for f in headers.fields { text += "\(f.name.name): \(Self.clean(f.value))\r\n" }
		try await c.send(Data((text + "\r\n").utf8))
		if headOnly { return }
		switch response.body {
		case .empty: break
		case let .data(d): try await c.send(d)
		case let .file(path, offset, length): try await sendFile(c, path: path, offset: offset, length: length)
		case let .stream(produce):
			let writer = BodyWriter { data in
				if chunked {
					var frame = Data(String(data.count, radix: 16).utf8 + [13, 10])
					frame.append(data)
					frame.append(contentsOf: [13, 10])
					try await c.send(frame)
				} else {
					try await c.send(data)
				}
			}
			try await produce(writer)
			if chunked { try await c.send(Data("0\r\n\r\n".utf8)) }
			if !keepAlive || !chunked { try await c.send(Data(), endOfStream: true) }
		}
	}

	private func sendFile(_ c: NetworkConnection<TCP>, path: String, offset: Int64, length: Int64) async throws {
		guard length > 0 else { return }
		let fh = try FileHandle(forReadingFrom: URL(filePath: path))
		defer { try? fh.close() }
		try fh.seek(toOffset: UInt64(offset))
		var left = length
		while left > 0 {
			let n = Int(min(Int64(chunkSize), left))
			let chunk = try await Self.read(fh, n)
			guard !chunk.isEmpty else { throw HTTPServerError.closed } // the file shrank
			left -= Int64(chunk.count)
			try await c.send(chunk)
		}
	}

	/// Reads off the cooperative pool, so a slow network volume cannot stall other work.
	private static func read(_ fh: FileHandle, _ n: Int) async throws -> Data {
		try await withCheckedThrowingContinuation { cont in
			DispatchQueue.global(qos: .userInitiated).async {
				cont.resume(with: Result { try fh.read(upToCount: n) ?? Data() })
			}
		}
	}

	/// A header value cannot carry line breaks.
	private static func clean(_ v: String) -> String { v.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "") }

	private static func address(_ endpoint: NWEndpoint?) -> String {
		guard case let .hostPort(host, _)? = endpoint else { return "" }
		let s: String
		switch host {
		case let .ipv4(a): s = "\(a)"
		case let .ipv6(a): s = "\(a)"
		case let .name(n, _): s = n
		@unknown default: s = ""
		}
		return String(s.split(separator: "%").first ?? "")
	}
}

nonisolated enum HTTPServerError: Error {
	case invalidPort, closed
}

private nonisolated final class FailureBox: @unchecked Sendable {
	private let lock = NSLock()
	private var error: NWError?
	func set(_ e: NWError) { lock.withLock { error = e } }
	func get() -> NWError? { lock.withLock { error } }
}
