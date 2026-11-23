import Foundation

/// The dynamic range of a video.
struct HDR: Sendable, Equatable {
	/// "smpte2084" (PQ), "arib-std-b67" (HLG) or nil for SDR.
	var transfer: String?
	/// Dolby Vision profile, 0 without it.
	var dvProfile = 0

	/// Dolby Vision profile 5 has no usable picture without DV processing: tone mapping or a player that
	/// ignores the DV metadata shows it green and purple.
	var isDV5: Bool { dvProfile == 5 }

	/// Reads ffprobe "key=value" lines of the stream and its first frame; a file may carry the transfer
	/// only in the container or only in the bitstream.
	init(probe out: String) {
		for line in out.split(whereSeparator: \.isNewline) {
			let kv = line.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1).map(String.init)
			guard kv.count == 2 else { continue }
			if kv[0] == "color_transfer", ["smpte2084", "arib-std-b67"].contains(kv[1]) { transfer = kv[1] }
			if kv[0] == "dv_profile" { dvProfile = Int(kv[1]) ?? 0 }
		}
		if isDV5 { transfer = "smpte2084" } // its base layer is IPT-PQ, tagged unspecified or not at all
	}

	init(transfer: String? = nil, dvProfile: Int = 0) {
		self.transfer = transfer
		self.dvProfile = dvProfile
	}
}

extension Transcoder {
	func probeHDR(_ path: String) async -> HDR {
		guard let ffprobe,
		      let out = try? await Prober.run(ffprobe, ["-v", "error", "-select_streams", "v:0", "-read_intervals", "%+#1",
		                                                "-show_entries", "stream=color_transfer:stream_side_data=dv_profile:frame=color_transfer",
		                                                "-of", "default=nw=1", path], timeout: 5)
		else { return HDR() }
		return HDR(probe: String(decoding: out, as: UTF8.self))
	}
}
