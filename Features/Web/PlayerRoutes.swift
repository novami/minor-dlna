import Foundation

/// The web player: files the browser plays are served directly, others as fragmented MP4 (HLS in Safari)
/// started at a given time. Seeking in a converted stream restarts it from the new time.
nonisolated extension WebRoutes {
	/// No conversion keeps the colours of Dolby Vision profile 5 without libplacebo, which the bundled ffmpeg lacks.
	static let dv5Unsupported = "Video je v Dolby Vision profilu 5, který tento prohlížeč neumí. Přehrajte ho na televizi."

	struct PlayInfo: Encodable {
		struct Next: Encodable { var id, title: String }
		var id, title, kind: String
		var art: String?
		var durationMs, positionMs: Int
		var watched, direct, subs: Bool
		/// Play the next episode when this one ends.
		var autoNext: Bool
		/// Direct: the file; otherwise the MP4 stream without ?t=.
		var src: String
		var next: Next?
	}

	func registerPlayer(_ r: Router) {
		r.get("/api/play") { req in
			if let denied = guarding(req, .login) { return denied }
			let q = req.query
			guard let (o, path, plan) = playable(q["id"], hevc: q["hevc"] == "1") else { return error(.notFound, "Položka už neexistuje.") }
			if o.videoCodec == "hevc", q["dv"] != "1", transcoder.available, await transcoder.probeHDR(path).isDV5 {
				return error(.unprocessableContent, Self.dv5Unsupported)
			}
			let num = o.id.dropFirst()
			let entry = BrowseEntry(o)
			return json(PlayInfo(id: o.id, title: o.title, kind: entry.kind.rawValue, art: entry.artPath?.replacingOccurrences(of: "/tn.jpg", with: "/sm.jpg"),
			                     durationMs: o.durationMs ?? 0, positionMs: o.positionMs, watched: o.watched, direct: plan.isDirect,
			                     subs: o.subtitle != nil, autoNext: await tv.playsNextEpisode,
			                     src: plan.isDirect ? DIDL.mediaPath(o) : "/api/play/\(num)/stream.mp4",
			                     next: catalog.nextEpisode(o.id).map { .init(id: $0.id, title: $0.title) }))
		}
		r.get("/api/play/:id/stream.mp4") { req in
			if let denied = guarding(req, .login) { return denied }
			let q = req.query
			guard let (o, path, plan) = playable(req.parameters["id"], hevc: q["hevc"] == "1") else { return HTTPResponse(status: .notFound) }
			if plan.isDirect { return HTTPResponse(status: .found, headers: [.location: DIDL.mediaPath(o)]) }
			guard let lease = await transcoder.acquire() else { return error(.serviceUnavailable, HLSSessions.errBusy) }
			let start = seconds(q["t"])
			let args = Transcoder.mp4Args(plan, o, path: path, start: start, hardware: transcoder.hardware)
			let session = TranscodeSession(title: o.title, client: req.remoteIP, plan: "web-" + plan.key)
			return HTTPResponse(status: .ok, headers: [.contentType: plan.video == nil ? "audio/mp4" : "video/mp4", .cacheControl: "no-store"],
			                body: .stream { [transcoder] writer in
			                	try await transcoder.stream(args, session: session, from: start, lease: lease, to: writer)
			                })
		}
		r.post("/api/play/start") { req in
			if let denied = guarding(req, .login) { return denied }
			struct Body: Decodable {
				var id: String
				var t: Double?
				var hevc, dv, hls: Bool?
				/// iPhone or iPad whose Safari shows no HDR video.
				var sdr: Bool?
				/// The previous HLS session of this player.
				var stop: String?
			}
			guard let b = try? JSONDecoder().decode(Body.self, from: req.body) else { return error(.badRequest, "Neplatný požadavek.") }
			if let t = b.stop { await hls.stop(t) }
			guard let (o, path, plan0) = playable(b.id, hevc: b.hevc == true) else { return error(.notFound, "Položka už neexistuje.") }
			var plan = plan0
			if plan.isDirect { return error(.badRequest, "Soubor se přehrává přímo.") }
			// iOS Safari drops an HDR variant silently when it reports no (video-dynamic-range: high), even on an
			// HDR display, so it gets tone-mapped SDR; H.264 from HDR would keep PQ colours and look washed out.
			let hdr = b.hls == true && plan.video != nil ? await transcoder.probeHDR(path) : HDR()
			if hdr.isDV5, b.sdr == true || b.dv != true || plan.video != .copy { return error(.unprocessableContent, Self.dv5Unsupported) }
			if hdr.transfer != nil, b.sdr == true || plan.video == .h264 { plan.video = .sdr }
			var start = max(b.t ?? 0, 0)
			// Copied streams start at the keyframe before t; converted video would start later than copied audio.
			if plan.video == .copy || plan.audio == .copy { start = await transcoder.keyframe(path, before: start) }
			guard b.hls == true else {
				return json(StartReply(url: "/api/play/\(o.id.dropFirst())/stream.mp4?t=\(String(format: "%.3f", start))" + (b.hevc == true ? "&hevc=1" : ""),
				                       start: start))
			}
			do {
				let token = try await hls.start(o, path: path, plan: plan, from: start, hdr: hdr, client: req.remoteIP)
				// iOS needs the master playlist; a Mac gets the media playlist, which plays HDR also on an SDR display.
				return json(StartReply(url: "/hls/\(token)/index.m3u8", master: "/hls/\(token)/master.m3u8", token: token, start: start))
			} catch HLSSessions.StartError.busy {
				return error(.serviceUnavailable, HLSSessions.errBusy)
			} catch let HLSSessions.StartError.failed(msg) {
				return error(.internalServerError, "Převod se nepodařilo spustit: " + msg)
			} catch {
				return self.error(.internalServerError, "Převod se nepodařilo spustit.")
			}
		}
		r.post("/api/play/hls/stop") { req in
			if let denied = guarding(req, .login) { return denied }
			struct Body: Decodable { var token: String }
			if let b = try? JSONDecoder().decode(Body.self, from: req.body) { await hls.stop(b.token) }
			return json(["ok": true])
		}
		// The random token is the access check: Safari's media player may not send cookies.
		r.get("/hls/:token/:file") { req in await hlsFile(req.parameters["token"] ?? "", req.parameters["file"] ?? "") }
		r.get("/api/play/:id/subs.vtt") { req in
			if let denied = guarding(req, .login) { return denied }
			guard let id = req.parameters["id"], Int64(id) != nil, let path = catalog.media(Substring(id))?.subtitle,
			      let fh = FileHandle(forReadingAtPath: path) else { return HTTPResponse(status: .notFound) }
			defer { try? fh.close() }
			let vtt = Subtitles.vtt(try fh.read(upToCount: 5 << 20) ?? Data(), shift: seconds(req.query["t"]))
			return HTTPResponse(status: .ok, headers: [.contentType: "text/vtt; charset=utf-8", .cacheControl: "no-store"],
			                body: .data(Data((vtt).utf8)))
		}
		r.post("/api/position") { req in
			if let denied = guarding(req, .login) { return denied }
			struct Body: Decodable { var id: String; var positionMs: Int; var durationMs: Int? }
			guard let b = try? JSONDecoder().decode(Body.self, from: req.body), b.positionMs > 0,
			      b.id.first == "I", let path = catalog.media(b.id.dropFirst())?.path else { return error(.badRequest, "Neplatný požadavek.") }
			do {
				try store.savePosition(path: path, positionMs: b.positionMs, durationMs: max(b.durationMs ?? 0, 0))
			} catch {
				return self.error(.internalServerError, "Pozici se nepodařilo uložit.")
			}
			positionSaved()
			return json(["ok": true])
		}
	}

	/// A video or audio item by "I<n>" or "<n>", with its file and how the browser gets it.
	private func playable(_ id: String?, hevc: Bool) -> (CatalogObject, String, Plan)? {
		guard let id, case let n = id.first == "I" ? id.dropFirst() : Substring(id), Int64(n) != nil,
		      let o = catalog.media(n), let path = o.path, let kind = o.format?.kind, kind == .video || kind == .audio else { return nil }
		return (o, path, transcoder.available ? Plan.decideBrowser(o, hevc: hevc) : .direct)
	}

	private func seconds(_ v: String?) -> Double {
		guard let v, let f = Double(v), f >= 0, f <= 1e6 else { return 0 } // also rejects NaN
		return f
	}

	private func hlsFile(_ token: String, _ name: String) async -> HTTPResponse {
		guard HLSSessions.validName(name), let dir = await hls.dir(token) else { return HTTPResponse(status: .notFound) }
		guard name.hasSuffix(".m3u8") else {
			guard let data = try? Data(contentsOf: dir.appending(path: name)) else { return HTTPResponse(status: .notFound) }
			return HTTPResponse(status: .ok, headers: [.contentType: "video/mp4", .contentLength: String(data.count)],
			                body: .data(data))
		}
		// The first segments take a moment; the master is built once the media playlist has them.
		let index = dir.appending(path: "index.m3u8")
		var media: String?
		for _ in 0..<100 {
			if let s = try? String(contentsOf: index, encoding: .utf8), HLSPlaylist.ready(s) { media = s; break }
			if Task.isCancelled { return HTTPResponse(status: .notFound) }
			try? await Task.sleep(for: .milliseconds(200))
		}
		guard let media else { return HTTPResponse(status: .notFound) }
		let body = name == "master.m3u8" ? HLSPlaylist.master(dir: dir, media: media) : HLSPlaylist.startAtBeginning(media)
		return HTTPResponse(status: .ok, headers: [.contentType: "application/vnd.apple.mpegurl", .cacheControl: "no-cache"],
		                body: .data(Data((body).utf8)))
	}
}

nonisolated struct StartReply: Encodable {
	var url: String
	var master: String?
	var token: String?
	/// Where the stream really starts, the keyframe before the asked time when copying.
	var start: Double
}
