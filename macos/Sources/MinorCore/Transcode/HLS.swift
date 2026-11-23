import Foundation
import Synchronization

/// Converted streams for Safari, which plays media only with byte ranges or HLS. ffmpeg writes the segments
/// into a temporary folder that is removed when the player stops asking for it.
actor HLSSessions {
	static let errBusy = "Server právě převádí jiná videa, zkuste to za chvíli."

	private struct Session {
		var dir: URL
		var process: Process
		var info: TranscodeSession
		var last: ContinuousClock.Instant
	}

	private let transcoder: Transcoder
	private let root: URL
	private let idle: Duration
	private var sessions: [String: Session] = [:]
	private var reaper: Task<Void, Never>?

	init(transcoder: Transcoder, root: URL = FileManager.default.temporaryDirectory.appending(path: "cz.minordlna.app-hls"),
	     idle: Duration = .seconds(120)) {
		self.transcoder = transcoder
		self.root = root
		self.idle = idle
		try? FileManager.default.removeItem(at: root) // leftovers from a crash
	}

	enum StartError: Error { case busy, failed(String) }

	/// Starts ffmpeg for item o from start seconds and returns the session token, the access check of its URLs:
	/// Safari's media player may not send cookies. Copied video gets its HDR transfer written into the stream,
	/// as a file tagged only in its bitstream would otherwise reach the player marked SDR; Dolby Vision profile 5
	/// is copied as dvh1 with its configuration box, which a player needs to show it at all.
	func start(_ o: CatalogObject, path: String, plan p: Plan, from start: Double, hdr: HDR, client: String) async throws(StartError) -> String {
		guard let ffmpeg = transcoder.ffmpeg else { throw .failed("chybí ffmpeg") }
		guard let lease = await transcoder.acquire() else { throw .busy }
		let token = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
		let dir = root.appending(path: token)
		do {
			try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
		} catch { throw .failed(error.localizedDescription) }

		var a = Transcoder.baseArgs(p, path: path, start: start, hardware: transcoder.hardware,
		                            decodesInHardware: Transcoder.decodesInHardware(o), throttle: true)
		if p.video == .copy, hdr.isDV5 {
			a += ["-tag:v", "dvh1", "-strict", "unofficial"]
		} else if p.video == .copy, let t = hdr.transfer {
			a += ["-color_primaries", "bt2020", "-color_trc", t, "-colorspace", "bt2020nc"]
		}
		a = Transcoder.browserMux(a, p, hevcSource: o.videoCodec == "hevc" && !hdr.isDV5)
		a += ["-f", "hls", "-hls_time", "4", "-hls_list_size", "0", "-hls_playlist_type", "event",
		      "-hls_segment_type", "fmp4", "-hls_flags", "independent_segments+temp_file",
		      "-hls_fmp4_init_filename", "init.mp4", "-hls_segment_filename", dir.appending(path: "s%05d.m4s").path,
		      dir.appending(path: "index.m3u8").path]

		let proc = Process()
		proc.executableURL = URL(filePath: ffmpeg)
		proc.arguments = a
		proc.standardInput = FileHandle.nullDevice
		proc.standardOutput = FileHandle.nullDevice
		let err = Pipe()
		proc.standardError = err
		let stderr = Mutex(Data())
		err.fileHandleForReading.readabilityHandler = { h in
			let d = h.availableData
			if d.isEmpty { h.readabilityHandler = nil }
			stderr.withLock { $0.append(d); if $0.count > 4096 { $0 = $0.suffix(4096) } }
		}
		// The slot is free once ffmpeg exits, also while the player still reads the finished segments.
		let held = Mutex<Transcoder.Lease?>(lease)
		let info = TranscodeSession(title: o.title, client: client, plan: p.key)
		let title = "\(o.title) [hls \(p.key) from \(Int(start)) s to \(client)]"
		proc.terminationHandler = { [transcoder] pr in
			transcoder.untrack(info.id)
			held.withLock { $0 = nil }
			let msg = String(decoding: stderr.withLock { $0 }, as: UTF8.self)
			if pr.terminationReason == .exit, pr.terminationStatus != 0 {
				Log.server.error("hls \(title, privacy: .public) failed (\(pr.terminationStatus)): \(msg, privacy: .public)")
			}
		}
		do { try proc.run() } catch {
			held.withLock { $0 = nil }
			try? FileManager.default.removeItem(at: dir)
			throw .failed(error.localizedDescription)
		}
		transcoder.track(info)
		Log.server.info("hls \(title, privacy: .public): \(a.joined(separator: " "), privacy: .public)")
		sessions[token] = Session(dir: dir, process: proc, info: info, last: .now)
		if reaper == nil {
			reaper = Task { [weak self] in
				while !Task.isCancelled, await self?.reap() == true { try? await Task.sleep(for: .seconds(15)) }
			}
		}
		return token
	}

	/// Ends a session at once (the player closed or seeked elsewhere).
	func stop(_ token: String) {
		guard let s = sessions.removeValue(forKey: token) else { return }
		close(s)
	}

	/// The folder of an active session, which counts as used.
	func dir(_ token: String) -> URL? {
		sessions[token]?.last = .now
		return sessions[token]?.dir
	}

	/// Whether ffmpeg of the session still runs.
	func running(_ token: String) -> Bool { sessions[token]?.process.isRunning ?? false }

	private func close(_ s: Session) {
		if s.process.isRunning { s.process.terminate() }
		transcoder.untrack(s.info.id)
		let dir = s.dir
		// ffmpeg may still write for a moment after the signal.
		Task.detached {
			try? await Task.sleep(for: .seconds(1))
			try? FileManager.default.removeItem(at: dir)
		}
	}

	/// Closes idle sessions; false when none is left.
	private func reap() -> Bool {
		for (token, s) in sessions where ContinuousClock.now - s.last > idle {
			sessions[token] = nil
			close(s)
		}
		if sessions.isEmpty { reaper = nil }
		return !sessions.isEmpty
	}

	/// The files a session serves.
	static func validName(_ n: String) -> Bool {
		["master.m3u8", "index.m3u8", "init.mp4"].contains(n)
			|| (n.hasPrefix("s") && n.hasSuffix(".m4s") && (5...6).contains(n.count - 5) && n.dropFirst().dropLast(4).allSatisfy(\.isASCII) && n.dropFirst().dropLast(4).allSatisfy(\.isNumber))
	}
}
