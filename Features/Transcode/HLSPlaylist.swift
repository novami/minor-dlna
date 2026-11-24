import Foundation

/// Playlists for Safari. iOS aborts every segment download of a bare media playlist; it needs a master
/// playlist stating bandwidth and codecs, which ffmpeg leaves out for HEVC, so it is built from init.mp4.
nonisolated enum HLSPlaylist {
	/// A finished playlist or one listing at least 8 seconds, twice the segment length: Safari gives up on an
	/// empty playlist, and AVFoundation drops a live variant much shorter than three target durations.
	static func ready(_ m3u8: String) -> Bool {
		m3u8.contains("#EXT-X-ENDLIST") || durations(m3u8).reduce(0) { $0 + $1.seconds } >= 8
	}

	/// A growing EVENT playlist would otherwise start near its live end, skipping the film's start.
	static func startAtBeginning(_ m3u8: String) -> String {
		guard !m3u8.contains("#EXT-X-START"), let nl = m3u8.firstIndex(of: "\n") else { return m3u8 }
		return m3u8[...nl] + "#EXT-X-START:TIME-OFFSET=0,PRECISE=YES\n" + m3u8[m3u8.index(after: nl)...]
	}

	/// The master playlist of a stream whose media playlist already lists a segment.
	static func master(dir: URL, media: String) -> String {
		let info = StreamInfo(init: (try? Data(contentsOf: dir.appending(path: "init.mp4"))) ?? Data())
		var attrs = ["BANDWIDTH=\(bandwidth(dir: dir, media: media))"]
		if !info.codecs.isEmpty { attrs.append("CODECS=\"\(info.codecs.joined(separator: ","))\"") }
		if info.width > 0, info.height > 0 { attrs.append("RESOLUTION=\(info.width)x\(info.height)") }
		if let r = info.videoRange { attrs.append("VIDEO-RANGE=\(r)") }
		return "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-INDEPENDENT-SEGMENTS\n#EXT-X-STREAM-INF:\(attrs.joined(separator: ","))\nindex.m3u8\n"
	}

	private static func durations(_ m3u8: String) -> [(seconds: Double, file: String)] {
		let lines = m3u8.split(separator: "\n", omittingEmptySubsequences: false)
		return lines.indices.compactMap { i in
			guard lines[i].hasPrefix("#EXTINF:"), i + 1 < lines.count else { return nil }
			let v = Double(lines[i].dropFirst(8).trimmingCharacters(in: CharacterSet(charactersIn: ", \r"))) ?? 0
			return (v, lines[i + 1].trimmingCharacters(in: .whitespaces))
		}
	}

	/// The peak bit rate estimated from the first segment, with headroom.
	private static func bandwidth(dir: URL, media: String) -> Int {
		guard let first = durations(media).first, first.seconds > 0,
		      let size = (try? FileManager.default.attributesOfItem(atPath: dir.appending(path: (first.file as NSString).lastPathComponent).path))?[.size] as? Int
		else { return 20_000_000 }
		return Int(Double(size) * 8 / first.seconds * 1.5)
	}
}

/// Codecs, size and range from the sample descriptions of an fMP4 init segment.
nonisolated struct StreamInfo {
	var codecs: [String] = []
	var width = 0, height = 0
	/// "PQ", "HLG" or nil.
	var videoRange: String?

	init(init data: Data) {
		let b = [UInt8](data)
		for trak in Self.boxes(Self.child(b[...], "moov") ?? [], "trak") {
			guard let stsd = Self.child(trak, "mdia", "minf", "stbl", "stsd"), stsd.count >= 16 else { continue }
			let entry = stsd.dropFirst(8) // version, flags and entry count
			let size = Self.u32(entry)
			guard size >= 8, size <= entry.count else { continue }
			let kind = String(decoding: entry.dropFirst(4).prefix(4), as: UTF8.self)
			let body = entry.dropFirst(8).prefix(size - 8)
			switch kind {
			case "avc1", "avc3", "hvc1", "hev1", "dvh1", "dvhe":
				guard body.count >= 78 else { continue } // VisualSampleEntry fields before its child boxes
				width = Self.u16(body.dropFirst(24))
				height = Self.u16(body.dropFirst(26))
				let kids = body.dropFirst(78)
				if kind.hasPrefix("a") {
					if let c = Self.child(kids, "avcC"), c.count >= 4 {
						let c = Array(c)
						codecs.append(String(format: "%@.%02x%02x%02x", kind, c[1], c[2], c[3]))
					}
				} else if kind.hasPrefix("d") {
					if let c = Self.child(kids, "dvcC") ?? Self.child(kids, "dvvC"), c.count >= 4 {
						codecs.append(Self.dvCodec(kind, Array(c)))
						videoRange = "PQ"
					}
				} else if let c = Self.child(kids, "hvcC"), c.count >= 13 {
					codecs.append(Self.hevcCodec(kind, Array(c)))
				}
				if let colr = Self.child(kids, "colr"), colr.count >= 8, String(decoding: colr.prefix(4), as: UTF8.self) == "nclx" {
					switch Self.u16(colr.dropFirst(6)) { // transfer characteristics
					case 16: videoRange = "PQ"
					case 18: videoRange = "HLG"
					default: break
					}
				}
			case "mp4a": codecs.append("mp4a.40.2")
			case "ac-3", "ec-3", "fLaC", "Opus", "alac": codecs.append(kind)
			case ".mp3": codecs.append("mp4a.40.34")
			default: break
			}
		}
	}

	/// A Dolby Vision configuration record holds the profile in 7 bits and the level in 6 bits after the version bytes.
	static func dvCodec(_ kind: String, _ c: [UInt8]) -> String {
		String(format: "%@.%02d.%02d", kind, Int(c[2] >> 1), Int((c[2] & 1) << 5 | c[3] >> 3))
	}

	/// An HEVCDecoderConfigurationRecord as in RFC 6381, e.g. hvc1.2.4.L153.B0.
	static func hevcCodec(_ kind: String, _ c: [UInt8]) -> String {
		let space = ["", "A", "B", "C"][Int(c[1] >> 6)]
		let tier = c[1] & 0x20 != 0 ? "H" : "L"
		let compat = (UInt32(c[2]) << 24 | UInt32(c[3]) << 16 | UInt32(c[4]) << 8 | UInt32(c[5])).bitReversed
		var s = "\(kind).\(space)\(c[1] & 0x1f).\(String(compat, radix: 16, uppercase: true)).\(tier)\(c[12])"
		var cons = c[6..<12]
		while cons.last == 0 { cons = cons.dropLast() }
		for x in cons { s += "." + String(x, radix: 16, uppercase: true) }
		return s
	}

	private static func u32(_ b: ArraySlice<UInt8>) -> Int {
		b.count < 4 ? 0 : b.prefix(4).reduce(0) { $0 << 8 | Int($1) }
	}

	private static func u16(_ b: ArraySlice<UInt8>) -> Int {
		b.count < 2 ? 0 : b.prefix(2).reduce(0) { $0 << 8 | Int($1) }
	}

	/// Payloads of the top-level boxes of type t.
	private static func boxes(_ b: ArraySlice<UInt8>, _ t: String) -> [ArraySlice<UInt8>] {
		var out: [ArraySlice<UInt8>] = [], b = b
		while b.count >= 8 {
			let size = u32(b)
			guard size >= 8, size <= b.count else { break }
			if String(decoding: b.dropFirst(4).prefix(4), as: UTF8.self) == t { out.append(b.dropFirst(8).prefix(size - 8)) }
			b = b.dropFirst(size)
		}
		return out
	}

	/// Follows a path of box types and returns the payload of the last one.
	private static func child(_ b: ArraySlice<UInt8>, _ path: String...) -> ArraySlice<UInt8>? {
		var b = b
		for t in path {
			guard let f = boxes(b, t).first else { return nil }
			b = f
		}
		return b
	}
}

nonisolated private extension UInt32 {
	var bitReversed: UInt32 {
		var v = self, r: UInt32 = 0
		for _ in 0..<32 { r = r << 1 | v & 1; v >>= 1 }
		return r
	}
}
