import Foundation

/// Technical details and tags of a video or audio file, from ffprobe.
struct ProbeInfo: Sendable, Equatable {
	var durationMs: Int?
	var bitrate: Int?
	var container: String?
	var videoCodec: String?
	var width: Int?
	var height: Int?
	var pixFmt: String?
	var audioCodec: String?
	var channels: Int?
	var hasPicture = false
	/// Container tags with lowercased keys.
	var tags: [String: String] = [:]

	func tag(_ keys: String...) -> String? {
		for k in keys {
			if let v = tags[k]?.trimmingCharacters(in: .whitespaces), !v.isEmpty { return v }
		}
		return nil
	}

	/// Leading number of "3", "03/12" or "2019-05-01".
	static func number(_ s: String?) -> Int? {
		guard let s, let n = Int(s.prefix(while: \.isNumber)), n > 0 else { return nil }
		return n
	}
}

struct Prober: Sendable {
	struct Failed: Error, CustomStringConvertible {
		let description: String
	}

	let binary: String?

	/// Finds ffprobe in PATH or the Homebrew locations (apps launched from Finder get a minimal PATH).
	init(binary: String? = nil) {
		let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
		let candidates = path.split(separator: ":").map { "\($0)/ffprobe" } + ["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe"]
		self.binary = binary ?? candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
	}

	var available: Bool { binary != nil }

	func probe(_ path: String, timeout: TimeInterval = 30) async throws -> ProbeInfo {
		guard let binary else { throw Failed(description: "ffprobe not found") }
		let out = try await Self.run(binary, ["-v", "error", "-print_format", "json",
		                                      "-show_entries", "format=format_name,duration,bit_rate:format_tags"
		                                      	+ ":stream=codec_type,codec_name,width,height,pix_fmt,channels:stream_disposition=attached_pic",
		                                      path], timeout: timeout)
		return try Self.parse(out)
	}

	static func parse(_ data: Data) throws -> ProbeInfo {
		struct Output: Decodable {
			struct Format: Decodable {
				var format_name: String?
				var duration: String?
				var bit_rate: String?
				var tags: [String: String]?
			}
			struct Stream: Decodable {
				struct Disposition: Decodable { var attached_pic: Int? }
				var codec_type: String?
				var codec_name: String?
				var width: Int?
				var height: Int?
				var pix_fmt: String?
				var channels: Int?
				var disposition: Disposition?
			}
			var format: Format?
			var streams: [Stream]?
		}
		let o = try JSONDecoder().decode(Output.self, from: data)
		var info = ProbeInfo()
		if let d = o.format?.duration.flatMap(Double.init), d > 0 { info.durationMs = Int(d * 1000) }
		info.bitrate = o.format?.bit_rate.flatMap { Int($0) }
		info.container = o.format?.format_name
		for (k, v) in o.format?.tags ?? [:] { info.tags[k.lowercased()] = v }
		for s in o.streams ?? [] {
			switch s.codec_type {
			case "video" where s.disposition?.attached_pic == 1:
				info.hasPicture = true
			case "video" where info.videoCodec == nil:
				(info.videoCodec, info.width, info.height, info.pixFmt) = (s.codec_name, s.width, s.height, s.pix_fmt)
			case "audio" where info.audioCodec == nil:
				(info.audioCodec, info.channels) = (s.codec_name, s.channels)
			default:
				break
			}
		}
		return info
	}

	/// Runs a tool off the cooperative pool and returns its stdout; kills it after the timeout.
	static func run(_ binary: String, _ args: [String], timeout: TimeInterval) async throws -> Data {
		try await withCheckedThrowingContinuation { cont in
			DispatchQueue.global(qos: .utility).async {
				let p = Process()
				p.executableURL = URL(filePath: binary)
				p.arguments = args
				let out = Pipe()
				p.standardOutput = out
				p.standardError = FileHandle.nullDevice
				do { try p.run() } catch { return cont.resume(throwing: error) }
				let timer = DispatchWorkItem { p.terminate() }
				DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
				let data = out.fileHandleForReading.readDataToEndOfFile()
				p.waitUntilExit()
				timer.cancel()
				if p.terminationStatus == 0 {
					cont.resume(returning: data)
				} else {
					cont.resume(throwing: Failed(description: "\((binary as NSString).lastPathComponent) exited with \(p.terminationStatus)"))
				}
			}
		}
	}
}
