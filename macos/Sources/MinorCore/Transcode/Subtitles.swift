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
