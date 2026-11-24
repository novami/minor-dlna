import Foundation

/// Parses the head of an HTTP/1.x request; everything is bounded, since the server is open to the whole LAN.
nonisolated enum HTTPParser {
	static let maxHeaderBytes = 16 * 1024
	static let maxHeaders = 64
	static let maxBodyBytes = 1 << 20

	struct Head: Sendable {
		var method: HTTPMethod
		var path: String
		var query: [String: String]
		var headers: HTTPHeaders
		var http11: Bool
		var contentLength: Int
		/// The client wants the connection closed after the response.
		var close: Bool
	}

	enum Result {
		case needMore
		case head(Head, consumed: Int)
		case invalid(HTTPStatus)
	}

	static func parseHead(_ buffer: Data) -> Result {
		let terminator = Data("\r\n\r\n".utf8)
		guard let end = buffer.range(of: terminator) else {
			return buffer.count > maxHeaderBytes ? .invalid(.headerFieldsTooLarge) : .needMore
		}
		guard end.lowerBound - buffer.startIndex <= maxHeaderBytes else { return .invalid(.headerFieldsTooLarge) }
		guard let text = String(data: buffer[buffer.startIndex..<end.lowerBound], encoding: .utf8) else { return .invalid(.badRequest) }
		var lines = text.components(separatedBy: "\r\n")
		let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: false)
		guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1."), requestLine[0].allSatisfy({ $0.isLetter }) else { return .invalid(.badRequest) }
		let target = String(requestLine[1])
		guard target.hasPrefix("/"), target.utf8.count <= 4096 else { return .invalid(target.hasPrefix("/") ? .uriTooLong : .badRequest) }

		var headers = HTTPHeaders()
		guard lines.count <= maxHeaders else { return .invalid(.headerFieldsTooLarge) }
		for line in lines {
			guard let colon = line.firstIndex(of: ":"), colon != line.startIndex, !line.hasPrefix(" "), !line.hasPrefix("\t") else {
				return .invalid(.badRequest)
			}
			headers.append(HTTPHeaderName(String(line[..<colon])), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
		}
		if headers[HTTPHeaderName("Transfer-Encoding")] != nil { return .invalid(.notImplemented) }
		var length = 0
		if let v = headers[.contentLength] {
			guard let n = Int(v), n >= 0 else { return .invalid(.badRequest) }
			guard n <= maxBodyBytes else { return .invalid(.payloadTooLarge) }
			length = n
		}

		let rawPath: Substring, rawQuery: Substring?
		if let q = target.firstIndex(of: "?") {
			rawPath = target[..<q]
			rawQuery = target[target.index(after: q)...]
		} else {
			(rawPath, rawQuery) = (target[...], nil)
		}
		guard let path = String(rawPath).removingPercentEncoding, !path.contains("\0") else { return .invalid(.badRequest) }
		// Nothing served here is addressed by a file path, so a ".." segment is never legitimate.
		if path.split(separator: "/", omittingEmptySubsequences: false).contains("..") || path.contains("\\") { return .invalid(.forbidden) }

		var query: [String: String] = [:]
		for pair in (rawQuery ?? "").split(separator: "&") {
			let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
			let decode = { (s: Substring) in String(s).replacingOccurrences(of: "+", with: " ").removingPercentEncoding }
			if let k = decode(kv[0]), let v = kv.count > 1 ? decode(kv[1]) : "" { query[k] = v }
		}
		let http11 = requestLine[2] == "HTTP/1.1"
		let connection = headers[.connection]?.lowercased() ?? ""
		let close = connection.contains("close") || (!http11 && !connection.contains("keep-alive"))
		let head = Head(method: HTTPMethod(String(requestLine[0])), path: path, query: query, headers: headers, http11: http11,
		                contentLength: length, close: close)
		return .head(head, consumed: end.upperBound - buffer.startIndex)
	}
}

/// A single byte range of a "Range" header.
nonisolated enum ByteRange {
	/// Parses a single "bytes=a-b", "bytes=a-" or "bytes=-n" range; nil when it cannot be satisfied.
	static func parse(_ header: String, size: Int64) -> ClosedRange<Int64>? {
		let h = header.trimmingCharacters(in: .whitespaces)
		guard h.lowercased().hasPrefix("bytes="), size > 0 else { return nil }
		let spec = h.dropFirst(6).split(separator: ",").first?.trimmingCharacters(in: .whitespaces) ?? ""
		let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
		guard parts.count == 2 else { return nil }
		if parts[0].isEmpty { // suffix
			guard let n = Int64(parts[1]), n > 0 else { return nil }
			return max(size - n, 0)...(size - 1)
		}
		guard let start = Int64(parts[0]), start < size else { return nil }
		if parts[1].isEmpty { return start...(size - 1) }
		guard let end = Int64(parts[1]), end >= start else { return nil }
		return start...min(end, size - 1)
	}
}
