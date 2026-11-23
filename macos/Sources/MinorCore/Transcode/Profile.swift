import Foundation
import Synchronization

/// What a client plays natively (ffprobe names; containers are the first component of format_name). nil means anything.
struct Profile: Sendable, Equatable {
	var name: String
	var containers: Set<String>?
	var videoCodecs: Set<String>?
	var audioCodecs: Set<String>?
	/// 10-bit H.264 (10-bit HEVC/VP9/AV1 are covered by the codec itself).
	var video10BitH264 = false

	/// Desktop players handle almost any format, so everything plays as-is.
	static let generic = Profile(name: "generic")

	private struct Brand {
		var id: String
		var markers: [String]
		var containers: Set<String>
		var video: Set<String>
		var audio: Set<String>
	}

	private static let pcm: Set<String> = ["pcm_s16le", "pcm_s24le", "pcm_s16be", "pcm_s24be", "pcm_u8"]
	private static let baseAudio = pcm.union(["aac", "ac3", "eac3", "mp3", "mp2", "flac"])
	private static let baseVideo: Set<String> = ["h264", "hevc", "mpeg2video", "mpeg4"]
	private static let baseContainers: Set<String> = ["matroska", "mov", "mpegts", "avi", "mpeg", "flac", "mp3", "wav", "aac"]

	/// In detection order: Roku first (Roku TVs carry another maker's name too), then makers, then shared platforms.
	private static let brands = [
		Brand(id: "roku", markers: ["roku"], containers: ["matroska", "mov", "mpegts", "flac", "mp3", "wav", "aac"],
		      video: ["h264", "hevc", "vp9", "mpeg2video"], audio: baseAudio),
		Brand(id: "lg", markers: ["lge", "webos", "lg-", "lg ", "lg electronics"], containers: baseContainers.union(["ogg"]),
		      video: baseVideo.union(["vp9", "av1", "vc1"]), audio: baseAudio.union(["vorbis", "opus"])),
		Brand(id: "samsung", markers: ["samsung", "sec_hhp", "tizen"], containers: baseContainers.union(["ogg", "asf"]),
		      video: baseVideo.union(["vp9", "av1", "vc1", "wmv3"]), audio: baseAudio.union(["vorbis", "opus", "wmav2"])),
		Brand(id: "sony", markers: ["bravia", "sony"], containers: baseContainers.union(["ogg"]),
		      video: baseVideo.union(["vp9"]), audio: baseAudio.union(["vorbis", "opus"])),
		Brand(id: "panasonic", markers: ["panasonic", "viera"], containers: baseContainers, video: baseVideo.union(["vp9"]), audio: baseAudio),
		Brand(id: "hisense", markers: ["hisense", "vidaa"], containers: baseContainers, video: baseVideo.union(["vp9"]), audio: baseAudio),
		Brand(id: "android", markers: ["android", "google", "tcl", "philips", "xiaomi", "mibox", "shield", "chromecast", "exoplayer", "dalvik"],
		      containers: ["matroska", "mov", "mpegts", "mpeg", "flac", "mp3", "wav", "ogg", "aac"],
		      video: ["h264", "hevc", "vp9", "mpeg2video"], audio: baseAudio.union(["vorbis", "opus"])),
		Brand(id: "tv", markers: ["toshiba", "grundig", "sharp", "metz", "vestel", "jvc", "telefunken", "thomson", "finlux", "loewe", "dlnadoc"],
		      containers: ["matroska", "mov", "mpegts", "mpeg", "mp3", "flac", "wav", "aac"],
		      video: ["h264", "hevc", "mpeg2video"], audio: baseAudio),
	]

	static func named(_ id: String, dts: Bool) -> Profile? {
		if id == generic.name { return generic }
		guard let b = brands.first(where: { $0.id == id }) else { return nil }
		return Profile(name: b.id, containers: b.containers, videoCodecs: b.video, audioCodecs: dts ? b.audio.union(["dts"]) : b.audio)
	}

	/// Picks a profile id from identification text: User-Agent, X-AV-Client-Info, renderer maker and model.
	static func detectID(_ ident: String) -> String {
		let s = ident.lowercased()
		return brands.first { $0.markers.contains(where: s.contains) }?.id ?? generic.name
	}
}

/// Picks the profile for each client IP from everything it has sent so far: a TV's player often names
/// no brand in its User-Agent, but another request from the same TV does.
final class ClientProfiles: Sendable {
	private struct Seen {
		var ident: String
		var at: Date
	}

	let dts: Bool
	private let clients = Mutex<[String: Seen]>([:])
	/// IP → profile id chosen by the user.
	private let chosen: Mutex<[String: String]>

	init(dts: Bool, chosen: [String: String] = [:]) {
		self.dts = dts
		self.chosen = Mutex(chosen)
	}

	func profile(ip: String, ident: String) -> Profile {
		let all = clients.withLock { c in
			let ident = ident.trimmingCharacters(in: .whitespaces)
			var seen = c[ip] ?? Seen(ident: "", at: .now)
			if !ident.isEmpty, !seen.ident.contains(ident), seen.ident.count < 1024 {
				seen.ident = seen.ident.isEmpty ? ident : seen.ident + " | " + ident
			}
			seen.at = .now
			if c[ip] == nil, c.count >= 200, let oldest = c.min(by: { $0.value.at < $1.value.at })?.key { c[oldest] = nil }
			c[ip] = seen
			return seen.ident
		}
		if let id = chosen.withLock({ $0[ip] }), let p = Profile.named(id, dts: dts) { return p }
		return Profile.named(Profile.detectID(all), dts: dts) ?? .generic
	}

	/// Applies at once; the next request from the address uses it.
	func choose(_ c: [String: String]) { chosen.withLock { $0 = c } }

	/// Clients seen since start, plus chosen ones that have not come back yet; most recent first.
	func list() -> [ClientInfo] {
		let chosen = chosen.withLock { $0 }
		var out = clients.withLock { c in
			c.map { ip, s in ClientInfo(ip: ip, ident: s.ident, detected: Profile.detectID(s.ident), chosen: chosen[ip], lastSeen: s.at) }
		}
		let seen = Set(out.map(\.ip))
		out += chosen.filter { !seen.contains($0.key) }
			.map { ClientInfo(ip: $0.key, ident: "", detected: Profile.generic.name, chosen: $0.value, lastSeen: .distantPast) }
		return out.sorted { ($0.lastSeen, $1.ip) > ($1.lastSeen, $0.ip) }
	}
}
