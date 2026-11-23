import Foundation

enum Subtitles {
	/// /subs/<item>.srt
	static func path(item: Int64) -> String { "/subs/\(item).srt" }

	/// Strips a BOM and converts non-UTF-8 text from Windows-1250 (usual for older Czech subtitles).
	static func utf8(_ data: Data) -> Data {
		let d = data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data[...]
		if String(data: d, encoding: .utf8) != nil { return Data(d) }
		return String(data: d, encoding: .windowsCP1250).map { Data($0.utf8) } ?? Data(d)
	}
}

extension Subtitles {
	/// SubRip as WebVTT for browsers, cues moved shift seconds earlier: a converted stream started mid-file
	/// has its timeline start at zero. Cues ending before zero are dropped.
	static func vtt(_ srt: Data, shift: Double) -> String {
		var out = "WEBVTT\n\n"
		let lines = String(decoding: utf8(srt), as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
			.split(separator: "\n", omittingEmptySubsequences: false)
		var i = 0
		while i < lines.count {
			let parts = lines[i].components(separatedBy: "-->")
			i += 1
			guard parts.count == 2 else { continue }
			var text: [Substring] = []
			while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
				text.append(lines[i])
				i += 1
			}
			guard let from = srtTime(parts[0]), let to = srtTime(parts[1]), to - shift > 0, !text.isEmpty else { continue }
			out += "\(vttTime(max(from - shift, 0))) --> \(vttTime(to - shift))\n\(text.joined(separator: "\n"))\n\n"
		}
		return out
	}

	/// "01:02:03,456", optionally followed by cue settings.
	private static func srtTime(_ s: String) -> Double? {
		guard let f = s.split(whereSeparator: \.isWhitespace).first else { return nil }
		let parts = f.replacingOccurrences(of: ",", with: ".").split(separator: ":", omittingEmptySubsequences: false)
		guard parts.count == 3 else { return nil }
		var secs = 0.0
		for p in parts {
			guard let v = Double(p), v >= 0 else { return nil }
			secs = secs * 60 + v
		}
		return secs
	}

	private static func vttTime(_ secs: Double) -> String {
		let ms = Int(secs * 1000 + 0.5)
		return String(format: "%02d:%02d:%02d.%03d", ms / 3_600_000, ms / 60000 % 60, ms / 1000 % 60, ms % 1000)
	}
}
