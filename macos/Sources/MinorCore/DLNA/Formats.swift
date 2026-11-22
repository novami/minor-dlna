import Foundation

public enum MediaKind: Sendable {
	case video, image, audio
}

public struct MediaFormat: Sendable, Equatable {
	public let kind: MediaKind
	public let mime: String

	static let byExtension: [String: MediaFormat] = [
		"mkv": .init(kind: .video, mime: "video/x-matroska"),
		"mp4": .init(kind: .video, mime: "video/mp4"),
		"m4v": .init(kind: .video, mime: "video/mp4"),
		"mov": .init(kind: .video, mime: "video/quicktime"),
		"avi": .init(kind: .video, mime: "video/x-msvideo"),
		"ts": .init(kind: .video, mime: "video/mp2t"),
		"m2ts": .init(kind: .video, mime: "video/vnd.dlna.mpeg-tts"),
		"mts": .init(kind: .video, mime: "video/vnd.dlna.mpeg-tts"),
		"mpg": .init(kind: .video, mime: "video/mpeg"),
		"mpeg": .init(kind: .video, mime: "video/mpeg"),
		"webm": .init(kind: .video, mime: "video/webm"),
		"wmv": .init(kind: .video, mime: "video/x-ms-wmv"),
		"jpg": .init(kind: .image, mime: "image/jpeg"),
		"jpeg": .init(kind: .image, mime: "image/jpeg"),
		"png": .init(kind: .image, mime: "image/png"),
		"gif": .init(kind: .image, mime: "image/gif"),
		"mp3": .init(kind: .audio, mime: "audio/mpeg"),
		"flac": .init(kind: .audio, mime: "audio/flac"),
		"m4a": .init(kind: .audio, mime: "audio/mp4"),
		"aac": .init(kind: .audio, mime: "audio/aac"),
		"wav": .init(kind: .audio, mime: "audio/wav"),
		"ogg": .init(kind: .audio, mime: "audio/ogg"),
	]

	public static func lookup(_ path: String) -> MediaFormat? {
		byExtension[(path as NSString).pathExtension.lowercased()]
	}

	/// 4th field of protocolInfo, also the contentFeatures.dlna.org header. OP=01 announces byte-range seeking.
	/// FLAGS: streaming or interactive transfer, background transfer, connection stalling, DLNA 1.5.
	public var contentFeatures: String {
		let flags = kind == .image ? "00D00000000000000000000000000000" : "01700000000000000000000000000000"
		return "DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=\(flags)"
	}

	public var protocolInfo: String { "http-get:*:\(mime):\(contentFeatures)" }

	public var transferMode: String { kind == .image ? "Interactive" : "Streaming" }

	/// Everything the server can serve (ConnectionManager GetProtocolInfo).
	public static var sourceProtocolInfo: String {
		Set(byExtension.values.map(\.mime)).sorted().map { "http-get:*:\($0):*" }.joined(separator: ",")
	}
}

extension String {
	var xmlEscaped: String {
		var out = ""
		out.reserveCapacity(utf8.count)
		for c in unicodeScalars {
			switch c {
			case "&": out += "&amp;"
			case "<": out += "&lt;"
			case ">": out += "&gt;"
			case "\"": out += "&quot;"
			case "'": out += "&apos;"
			// XML 1.0 forbids most control characters; file names may contain them.
			case _ where c.value < 0x20 && c != "\t" && c != "\n" && c != "\r": continue
			default: out.unicodeScalars.append(c)
			}
		}
		return out
	}
}
