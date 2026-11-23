import Foundation

/// How a file reaches the client; both nil is direct play. The plan is part of the stream URL,
/// so the streaming request does not depend on which player component fetches it.
struct Plan: Sendable, Equatable {
	enum Video: String, Sendable { case copy, h264 }
	enum Audio: String, Sendable { case copy, aac, ac3, flac }

	var video: Video?
	var audio: Audio?

	static let direct = Plan()
	var isDirect: Bool { self == .direct }

	/// "copy-ac3", "x-flac"
	var key: String { (video?.rawValue ?? "x") + "-" + (audio?.rawValue ?? "x") }

	/// Accepts only known values, so URL input never reaches ffmpeg arguments directly.
	init?(key: some StringProtocol) {
		let p = key.split(separator: "-", omittingEmptySubsequences: false)
		guard p.count == 2 else { return nil }
		let v = p[0] == "x" ? nil : Video(rawValue: String(p[0])), a = p[1] == "x" ? nil : Audio(rawValue: String(p[1]))
		guard v != nil || p[0] == "x", a != nil || p[1] == "x", v != nil || a != nil else { return nil }
		video = v
		audio = a
	}

	init(video: Video? = nil, audio: Audio? = nil) {
		self.video = video
		self.audio = audio
	}

	var mime: String { video == nil ? "audio/flac" : "video/mpeg" }
	var ext: String { video == nil ? "flac" : "ts" }

	/// Time-based seeking only: the output size is unknown, so byte ranges are not offered.
	static let contentFeatures = "DLNA.ORG_OP=10;DLNA.ORG_CI=1;DLNA.ORG_FLAGS=01700000000000000000000000000000"
	var protocolInfo: String { "http-get:*:\(mime):\(Self.contentFeatures)" }

	/// /transcode/<item>/<key>.<ext>
	func path(item: Int64) -> String { "/transcode/\(item)/\(key).\(ext)" }

	/// MPEG-TS can carry these when copying.
	private static let tsAudio: Set<String> = ["aac", "ac3", "eac3", "mp3", "mp2", "dts"]

	/// Direct play when the profile allows it, otherwise the cheapest conversion.
	static func decide(_ p: Profile, _ o: CatalogObject) -> Plan {
		guard let kind = o.format?.kind, kind != .image else { return .direct }
		let container = o.container?.split(separator: ",").first.map(String.init) ?? ""
		// Unknown details (no ffprobe yet or it failed): try direct play rather than guessing.
		if container.isEmpty || (kind == .video && (o.videoCodec ?? "").isEmpty) { return .direct }
		let containerOK = p.containers?.contains(container) ?? true
		let audioOK = o.audioCodec.map { p.audioCodecs?.contains($0) ?? true } ?? true

		if kind == .audio { return containerOK && audioOK ? .direct : Plan(audio: .flac) }

		let vc = o.videoCodec ?? ""
		var videoOK = p.videoCodecs?.contains(vc) ?? true
		if vc == "h264", is10Bit(o.pixFmt), !p.video10BitH264, p.videoCodecs != nil { videoOK = false }
		if containerOK, videoOK, audioOK { return .direct }

		var plan = Plan(video: .copy, audio: .copy)
		// MPEG-TS cannot carry VP9/AV1, so those are re-encoded when remuxing is needed.
		if !videoOK || vc == "vp9" || vc == "av1" { plan.video = .h264 }
		if let ac = o.audioCodec {
			if !audioOK || !tsAudio.contains(ac) { plan.audio = (o.channels ?? 0) > 2 ? .ac3 : .aac } // ac3 keeps 5.1
		} else {
			plan.audio = nil
		}
		return plan
	}

	static func is10Bit(_ pixFmt: String?) -> Bool {
		guard let f = pixFmt else { return false }
		return f.contains("10") || f.contains("12")
	}
}
