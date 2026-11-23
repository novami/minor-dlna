import Foundation
import Hummingbird
import NIOCore
import NIOPosix
import Synchronization

/// Streams converted media from ffmpeg: MPEG-TS for TVs, FLAC for audio.
final class Transcoder: Sendable {
	let ffmpeg: String?
	let ffprobe: String?
	let hardware: Bool
	private let maxSessions: Int
	private let active = Mutex(0)
	private let sessions = Mutex<[UUID: TranscodeSession]>([:])

	init(ffmpeg: String? = Thumbnails.findFFmpeg(), ffprobe: String? = Prober().binary, hardware: Bool, maxSessions: Int) {
		self.ffmpeg = ffmpeg
		self.ffprobe = ffprobe
		self.hardware = hardware
		self.maxSessions = max(maxSessions, 1)
	}

	var available: Bool { ffmpeg != nil }

	/// A held transcoding slot, released when the response body that owns it goes away.
	final class Lease: Sendable {
		private let release: @Sendable () -> Void
		init(_ release: @escaping @Sendable () -> Void) { self.release = release }
		deinit { release() }
	}

	/// Takes a slot; a player often reconnects at once, so the previous ffmpeg gets a moment to exit.
	func acquire() async -> Lease? {
		for _ in 0..<50 {
			let got = active.withLock { n in
				guard n < maxSessions else { return false }
				n += 1
				return true
			}
			if got {
				return Lease { self.active.withLock { $0 -= 1 } }
			}
			try? await Task.sleep(for: .milliseconds(100))
		}
		return nil
	}

	var running: Int { active.withLock { $0 } }

	var current: [TranscodeSession] { sessions.withLock { $0.values.sorted { $0.began < $1.began } } }

	/// The keyframe at or before t. A copied stream starts there; the other one is cut to match.
	func keyframe(_ path: String, before t: Double) async -> Double {
		guard t > 0, let ffprobe else { return max(t, 0) }
		let interval = String(format: "%.3f%%%.3f", max(t - 20, 0), t + 0.001)
		guard let out = try? await Prober.run(ffprobe, ["-v", "error", "-select_streams", "v:0", "-skip_frame", "nokey",
		                                                "-show_entries", "frame=pts_time", "-of", "csv=p=0", "-read_intervals", interval, path],
		                                      timeout: 5)
		else { return t }
		let best = String(decoding: out, as: UTF8.self).split(whereSeparator: \.isWhitespace)
			.compactMap { Double($0.trimmingCharacters(in: CharacterSet(charactersIn: ","))) }
			.filter { $0 <= t + 0.001 }.max()
		return best ?? t
	}

	/// ffmpeg arguments for a TV stream.
	static func args(_ p: Plan, path: String, start: Double, hardware: Bool, decodesInHardware: Bool) -> [String] {
		var a = ["-nostdin", "-hide_banner", "-v", "error", "-fflags", "+genpts"]
		if start > 0 { a += ["-ss", String(format: "%.3f", start)] }
		if p.video == .h264, hardware, decodesInHardware { a += ["-hwaccel", "videotoolbox"] }
		a += ["-i", path]
		if p.video == nil {
			a += ["-map", "0:a:0", "-vn"]
		} else {
			a += ["-map", "0:v:0"]
			if p.audio != nil { a += ["-map", "0:a:0?"] }
		}
		switch p.video {
		case .copy: a += ["-c:v", "copy"]
		case .h264:
			// Capped at 1080p: sources needing H.264 are older formats, and it keeps encoding real-time.
			a += ["-vf", "scale=w='min(1920,iw)':h=-2,format=yuv420p"]
			a += hardware
				? ["-c:v", "h264_videotoolbox", "-profile:v", "high", "-b:v", "10M", "-maxrate", "15M", "-bufsize", "20M"]
				: ["-c:v", "libx264", "-preset", "veryfast", "-crf", "20", "-profile:v", "high"]
			// Regular keyframes for seeking; VideoToolbox alone sets one every half second.
			a += ["-force_key_frames", "expr:gte(t,n_forced*2)", "-g", "600"]
		case nil: break
		}
		switch p.audio {
		case .copy: a += ["-c:a", "copy"]
		case .ac3: a += ["-c:a", "ac3", "-b:a", "640k", "-ac", "6"]
		case .aac: a += ["-c:a", "aac", "-b:a", "192k", "-ac", "2"]
		case .flac: a += ["-c:a", "flac"]
		case nil: break
		}
		if p.video == nil { return a + ["-f", "flac", "pipe:1"] }
		return a + ["-sn", "-dn", "-f", "mpegts", "-muxdelay", "0", "-muxpreload", "0", "pipe:1"]
	}

	/// VideoToolbox decodes these on every Apple Silicon Mac; AV1 before M3 fails outright instead of falling back.
	static func decodesInHardware(_ o: CatalogObject) -> Bool {
		o.videoCodec == "hevc" || (o.videoCodec == "h264" && !Plan.is10Bit(o.pixFmt))
	}

	/// Runs ffmpeg and writes its output until it ends or the client goes away.
	func stream(_ args: [String], session: TranscodeSession, from start: Double, lease: Lease, to writer: inout any ResponseBodyWriter) async throws {
		guard let ffmpeg else { return }
		let title = "\(session.title) [\(session.plan) from \(Int(start)) s to \(session.client)]"
		sessions.withLock { $0[session.id] = session }
		defer { sessions.withLock { $0[session.id] = nil } }
		let p = Process()
		p.executableURL = URL(filePath: ffmpeg)
		p.arguments = args
		let out = Pipe(), err = Pipe()
		p.standardInput = FileHandle.nullDevice
		p.standardOutput = out
		p.standardError = err
		let stderr = Mutex(Data())
		err.fileHandleForReading.readabilityHandler = { h in
			let d = h.availableData
			if d.isEmpty { h.readabilityHandler = nil } // EOF; the handler would otherwise fire again and again
			stderr.withLock { $0.append(d); if $0.count > 4096 { $0 = $0.suffix(4096) } }
		}
		let exited = AsyncStream<Int32>.makeStream()
		p.terminationHandler = { exited.continuation.yield($0.terminationStatus); exited.continuation.finish() }
		try p.run()
		let fd = dup(out.fileHandleForReading.fileDescriptor)
		try? out.fileHandleForReading.close()
		try? out.fileHandleForWriting.close()
		let began = ContinuousClock.now
		var sent = 0, clientGone = false
		defer {
			if p.isRunning { p.terminate() }
			withExtendedLifetime(lease) {}
		}
		Log.server.info("transcode \(title, privacy: .public): \(args.joined(separator: " "), privacy: .public)")
		do {
			let channel = try await NIOPipeBootstrap(group: MultiThreadedEventLoopGroup.singleton)
				.takingOwnershipOfDescriptor(input: fd) { ch in
					ch.eventLoop.makeCompletedFuture { try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: ch) }
				}
			try await channel.executeThenClose { inbound, _ in
				for try await buf in inbound {
					sent += buf.readableBytes
					do { try await writer.write(buf) } catch { clientGone = true; throw error }
				}
			}
		} catch where clientGone || Task.isCancelled {
			p.terminate()
			Log.server.info("transcode \(title, privacy: .public) stopped by client after \(sent >> 20) MB, \(String(describing: ContinuousClock.now - began), privacy: .public)")
			return
		}
		var status: Int32 = 0
		for await s in exited.stream { status = s }
		if status != 0, p.terminationReason == .exit {
			let msg = String(decoding: stderr.withLock { $0 }, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
			Log.server.error("transcode \(title, privacy: .public) failed (\(status)): \(msg, privacy: .public)")
		} else {
			Log.server.info("transcode \(title, privacy: .public) finished, \(sent >> 20) MB")
		}
		try await writer.finish(nil)
	}

	/// Start of "npt=123.4-", "npt=0:02:03.5-" or "npt=10-20" in seconds.
	static func parseNPT(_ header: String) -> Double? {
		let h = header.trimmingCharacters(in: .whitespaces)
		guard h.hasPrefix("npt=") else { return nil }
		let from = h.dropFirst(4).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
		if from.isEmpty || from == "now" { return 0 }
		let parts = from.split(separator: ":", omittingEmptySubsequences: false)
		guard parts.count <= 3 else { return nil }
		var secs = 0.0
		for part in parts {
			guard let v = Double(part), v >= 0, v.isFinite else { return nil }
			secs = secs * 60 + v
		}
		return secs
	}
}
