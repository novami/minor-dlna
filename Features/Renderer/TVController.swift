import Foundation

/// What the remote control in the app and the web shows.
nonisolated struct TVStatus: Sendable, Equatable, Codable {
	enum State: String, Sendable, Codable {
		case starting = "STARTING", waking = "WAKING", playing = "PLAYING", paused = "PAUSED_PLAYBACK"
		case transitioning = "TRANSITIONING", stopped = "STOPPED", noMedia = "NO_MEDIA_PRESENT"
	}

	var udn: String
	var tv: String
	var itemID: String
	var title: String
	var state: State
	var positionMs = 0
	var durationMs = 0
	var volume = 0
	var muted = false
	var canVolume = false
	var error: String?
}

nonisolated enum TVCommand: Sendable {
	case pause, play, stop
	case seek(ms: Int)
	case volume(Int)
	case mute(Bool)
}

/// Plays library items on one TV at a time and records how far they were watched.
actor TVController: BackgroundService {
	static let saveEvery: Duration = .seconds(10)
	/// TV boot until its renderer answers.
	static let wakeTimeout: Duration = .seconds(60)
	/// Missed polls before the TV counts as off.
	static let maxFailures = 5
	/// This close to the end counts as played through, so the next episode may follow.
	static let endSlackMs = 15000
	/// How long the final state of an ended session stays visible.
	static let lastShown: TimeInterval = 15

	private final class Session {
		var dev: Renderer
		var item: CatalogObject
		var uri = ""
		/// Position to seek to once playing, 0 = none.
		var resume = 0
		/// The TV reported PLAYING for this item.
		var started = false
		var saved = ContinuousClock.now
		var st: TVStatus
		var task: Task<Void, Never>?

		init(dev: Renderer, item: CatalogObject, st: TVStatus) {
			self.dev = dev
			self.item = item
			self.st = st
		}
	}

	let store: Store
	let catalog: LibraryCatalog
	let port: Int
	let profiles: ClientProfiles
	let transcode: Bool
	let pollEvery: Duration
	/// An item finished or stopped with new progress, so the TV's library view can show it.
	let onProgress: @Sendable () -> Void
	private var autoNext: Bool

	private var online: [String: Renderer] = [:]
	private var session: Session?
	private var last: (status: TVStatus, at: Date)?
	private var searching: Task<Void, any Error>?

	init(store: Store, catalog: LibraryCatalog, port: Int, profiles: ClientProfiles, transcode: Bool,
	     autoNext: Bool = false, pollEvery: Duration = .seconds(2), onProgress: @escaping @Sendable () -> Void) {
		self.store = store
		self.catalog = catalog
		self.port = port
		self.profiles = profiles
		self.transcode = transcode
		self.autoNext = autoNext
		self.pollEvery = pollEvery
		self.onProgress = onProgress
	}

	/// Searches once at start; at shutdown the running session saves its position.
	func run() async {
		do { _ = try await search() } catch { AppLog.server.notice("TV search: \(String(describing: error), privacy: .public)") }
		while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
		let task = session?.task
		task?.cancel()
		await task?.value
	}

	// MARK: Devices

	/// Every TV seen so far; online marks those that answered the last search.
	func devices() -> [Renderer] {
		((try? store.renderers()) ?? []).map { r in
			var r = r
			if let o = online[r.udn] { r.online = true; r.avTransport = o.avTransport; r.renderingControl = o.renderingControl }
			return r
		}
	}

	/// Looks for TVs and remembers them, with their MAC address for waking them later.
	func search() async throws -> [Renderer] {
		if let running = searching {
			try await running.value
			return devices()
		}
		let task = Task { try await self.doSearch() }
		searching = task
		defer { searching = nil }
		try await task.value
		return devices()
	}

	private func doSearch() async throws {
		let locations = try await Discovery.search(wait: .seconds(3))
		var found: [String: Renderer] = [:]
		await withTaskGroup(of: Renderer?.self) { g in
			for loc in locations { g.addTask { try? await UPnPClient.describe(loc) } }
			for await r in g { if let r, found[r.udn] == nil { found[r.udn] = r } }
		}
		for var r in found.values {
			r.mac = Discovery.mac(of: r.ip)
			AppLog.server.info("TV \(r.name, privacy: .public) at \(r.ip, privacy: .public), MAC \(r.mac.isEmpty ? "unknown" : "known", privacy: .public)")
			found[r.udn] = r
			_ = profiles.profile(ip: r.ip, ident: "\(r.maker) \(r.model) \(r.name)")
			try store.saveRenderer(r)
		}
		online = found
		AppLog.server.info("TVs found: \(found.count)")
	}

	private func known(_ udn: String) throws -> Renderer {
		guard let d = devices().first(where: { $0.udn == udn }) else { throw TVError("Neznámá televize.") }
		return d
	}

	/// Turns the TV on over the network.
	func wake(_ udn: String) async throws {
		let d = try known(udn)
		guard !d.mac.isEmpty else { throw TVError("MAC adresa televize není známá – zapněte ji jednou ručně, server si ji zapamatuje.") }
		try await Discovery.wake(mac: d.mac)
	}

	func setAutoNext(_ on: Bool) { autoNext = on }
	/// The web player follows the same setting.
	var playsNextEpisode: Bool { autoNext }

	// MARK: Session

	/// The running session, or the final state of one that just ended.
	func status() -> TVStatus? {
		if let s = session { return s.st }
		if let last, Date().timeIntervalSince(last.at) < Self.lastShown { return last.status }
		return nil
	}

	/// Starts item id on the TV, from fromMs when positive. Returns at once;
	/// waking the TV and loading show up in status().
	func play(udn: String, id: String, fromMs: Int) throws {
		guard let item = try? catalog.metadata(id), !item.isContainer, let kind = item.format?.kind, kind == .video || kind == .audio else {
			throw TVError("Tuto položku nelze přehrát na TV.")
		}
		let d = try known(udn)
		let s = Session(dev: d, item: item, st: TVStatus(udn: d.udn, tv: d.name, itemID: item.id, title: item.title, state: .starting,
		                                                 durationMs: item.durationMs ?? 0))
		s.resume = max(fromMs, 0)
		session?.task?.cancel()
		session = s
		last = nil
		s.task = Task { await self.run(s) }
	}

	private func run(_ s: Session) async {
		do {
			let dev = try await reach(s)
			guard isCurrent(s) else { return }
			s.dev = dev
			s.st.canVolume = dev.renderingControl != nil
			try await load(s)
		} catch {
			if isCurrent(s) { end(s, error is TVError ? "\(error)" : "Televize odmítla přehrávání: \(Self.describe(error))") }
			return
		}
		var failures = 0
		while isCurrent(s) {
			try? await Task.sleep(for: pollEvery)
			guard isCurrent(s) else { break }
			do {
				if try await poll(s) { return }
				failures = 0
			} catch {
				guard isCurrent(s) else { break }
				failures += 1
				if failures >= Self.maxFailures {
					save(s)
					end(s, "Televize přestala odpovídat.")
					return
				}
			}
		}
		save(s)
	}

	private static func describe(_ e: any Error) -> String {
		e is TVError || e is UPnPFault ? String(describing: e) : e.localizedDescription
	}

	private func isCurrent(_ s: Session) -> Bool { session === s && !Task.isCancelled }

	/// The TV ready to take commands, woken when it does not answer and its MAC is known.
	private func reach(_ s: Session) async throws -> Renderer {
		if var d = try? await UPnPClient.describe(s.dev.location) {
			d.mac = s.dev.mac
			return d
		}
		guard !s.dev.mac.isEmpty else { throw TVError("Televize neodpovídá. Zapněte ji a povolte na ní sdílení obsahu (DLNA).") }
		s.st.state = .waking
		let deadline = ContinuousClock.now + Self.wakeTimeout
		var lastWake: ContinuousClock.Instant?
		while ContinuousClock.now < deadline {
			try Task.checkCancellation()
			if lastWake.map({ ContinuousClock.now - $0 > .seconds(15) }) ?? true {
				do { try await Discovery.wake(mac: s.dev.mac) } catch { throw TVError("Televizi se nepodařilo zapnout: \(Self.describe(error))") }
				lastWake = .now
			}
			// After a boot the renderer may listen on another port: look it up again.
			for loc in (try? await Discovery.search(wait: .seconds(2))) ?? [] {
				guard var d = try? await UPnPClient.describe(loc), d.udn == s.dev.udn else { continue }
				d.mac = s.dev.mac
				try? store.saveRenderer(d)
				online[d.udn] = d
				return d
			}
		}
		throw TVError("Televize se nezapnula. Povolte na ní zapnutí přes Wi-Fi/LAN.")
	}

	/// Hands the stream to the TV and starts playback.
	private func load(_ s: Session) async throws {
		guard let avt = s.dev.avTransport, let format = s.item.format else { throw TVError("Televize nemá AVTransport.") }
		let ifc = LANInterface.parse(s.dev.ip).flatMap { a in LANInterface.all().first { $0.contains(a) } } ?? LANInterface.all().first
		guard let ifc else { throw TVError("Mac není připojený k místní síti.") }
		let base = "http://\(ifc.ip):\(port)"
		let profile = transcode ? profiles.profile(ip: s.dev.ip, ident: "\(s.dev.maker) \(s.dev.model) \(s.dev.name)") : nil
		s.uri = base + DIDL.stream(s.item, format, profile).path
		let meta = DIDL.render([s.item], baseURL: base, profile: profile)
		AppLog.tv.info("play to TV \(s.dev.name, privacy: .public): \(s.item.title, privacy: .private) from \(s.resume)")
		// Some TVs refuse a new URI while another one plays.
		_ = try? await UPnPClient.call(avt, UPnPClient.avTransport, "Stop", ["InstanceID": "0"])
		_ = try await UPnPClient.call(avt, UPnPClient.avTransport, "SetAVTransportURI",
		                              ["InstanceID": "0", "CurrentURI": s.uri, "CurrentURIMetaData": meta])
		_ = try await UPnPClient.call(avt, UPnPClient.avTransport, "Play", ["InstanceID": "0", "Speed": "1"])
	}

	/// Reads the TV state; true means the session ended.
	private func poll(_ s: Session) async throws -> Bool {
		guard let avt = s.dev.avTransport else { return false }
		let ti = try await UPnPClient.call(avt, UPnPClient.avTransport, "GetTransportInfo", ["InstanceID": "0"])
		let pi = try await UPnPClient.call(avt, UPnPClient.avTransport, "GetPositionInfo", ["InstanceID": "0"])
		var volume: Int?, muted: Bool?
		if let rc = s.dev.renderingControl {
			volume = (try? await UPnPClient.call(rc, UPnPClient.renderingControl, "GetVolume", ["InstanceID": "0", "Channel": "Master"]))
				.flatMap { Int($0["CurrentVolume"] ?? "") }
			muted = (try? await UPnPClient.call(rc, UPnPClient.renderingControl, "GetMute", ["InstanceID": "0", "Channel": "Master"]))
				.map { $0["CurrentMute"] == "1" || $0["CurrentMute"]?.lowercased() == "true" }
		}
		guard isCurrent(s) else { return true }

		// The TV now plays something else: someone started other content on it.
		if s.started, let track = pi["TrackURI"], !track.isEmpty, !UPnPClient.sameURI(track, s.uri) {
			save(s)
			end(s, nil)
			return true
		}
		let state = TVStatus.State(rawValue: ti["CurrentTransportState"] ?? "") ?? .transitioning
		let playing = state == .playing || state == .paused
		let pos = UPnPClient.parseTime(pi["RelTime"] ?? "")
		s.st.state = state
		if playing, let pos, pos > 0 || !s.started { s.st.positionMs = pos }
		if let dur = UPnPClient.parseTime(pi["TrackDuration"] ?? ""), dur > 0 { s.st.durationMs = dur }
		if let volume { s.st.volume = volume }
		if let muted { s.st.muted = muted }

		if playing {
			s.started = true
			if s.resume > 0, state == .playing {
				let to = s.resume
				s.resume = 0
				do { try await seek(s, to) } catch { AppLog.server.warning("resume seek: \(String(describing: error), privacy: .public)") }
			}
			if ContinuousClock.now - s.saved >= Self.saveEvery { save(s) }
			return false
		}
		guard s.started, state == .stopped || state == .noMedia else { return false }

		// Stopped after playing: by the user, or at the end.
		save(s)
		let atEnd = s.st.durationMs > 0 && s.st.positionMs >= s.st.durationMs - Self.endSlackMs
		if atEnd, autoNext, let next = catalog.nextEpisode(s.item.id) {
			onProgress()
			s.item = next
			s.started = false
			s.resume = next.watched ? 0 : next.positionMs
			s.st = TVStatus(udn: s.st.udn, tv: s.st.tv, itemID: next.id, title: next.title, state: .starting, durationMs: next.durationMs ?? 0,
			                volume: s.st.volume, muted: s.st.muted, canVolume: s.st.canVolume)
			do {
				try await load(s)
			} catch {
				if isCurrent(s) { end(s, "Další díl se nepodařilo spustit: \(Self.describe(error))") }
				return true
			}
			return false
		}
		end(s, nil)
		return true
	}

	/// Closes the session, keeping its last state for the UI.
	private func end(_ s: Session, _ error: String?) {
		guard session === s else { return }
		var st = s.st
		st.state = .stopped
		st.error = error
		session = nil
		last = (st, Date())
		s.task?.cancel()
		onProgress()
	}

	/// Stores the watch position of the session's item.
	private func save(_ s: Session) {
		guard s.started, s.st.positionMs > 0, let path = s.item.path else { return }
		s.saved = .now
		do {
			try store.savePosition(path: path, positionMs: s.st.positionMs, durationMs: s.st.durationMs > 0 ? s.st.durationMs : s.item.durationMs ?? 0)
		} catch {
			AppLog.server.warning("save position: \(error, privacy: .public)")
		}
	}

	private func refreshPosition(_ s: Session) async {
		guard let avt = s.dev.avTransport, s.started,
		      let pi = try? await UPnPClient.call(avt, UPnPClient.avTransport, "GetPositionInfo", ["InstanceID": "0"]),
		      let pos = UPnPClient.parseTime(pi["RelTime"] ?? ""), pos > 0 else { return }
		s.st.positionMs = pos
	}

	private func seek(_ s: Session, _ ms: Int) async throws {
		guard let avt = s.dev.avTransport else { return }
		let target = UPnPClient.formatTime(ms)
		do {
			_ = try await UPnPClient.call(avt, UPnPClient.avTransport, "Seek", ["InstanceID": "0", "Unit": "REL_TIME", "Target": target])
		} catch {
			// Some renderers only take ABS_TIME.
			_ = try await UPnPClient.call(avt, UPnPClient.avTransport, "Seek", ["InstanceID": "0", "Unit": "ABS_TIME", "Target": target])
		}
		s.st.positionMs = ms
	}

	/// Controls the running session.
	func command(_ c: TVCommand) async throws {
		guard let s = session else { throw TVError("Na televizi nic nehraje.") }
		// Stop also cancels waking or connecting to the TV.
		if case .stop = c, s.st.state == .waking || s.st.state == .starting {
			end(s, nil)
			if let avt = s.dev.avTransport { _ = try? await UPnPClient.call(avt, UPnPClient.avTransport, "Stop", ["InstanceID": "0"]) }
			return
		}
		guard let avt = s.dev.avTransport else { throw TVError("Televize se ještě připojuje.") }
		do {
			switch c {
			case .pause:
				_ = try await UPnPClient.call(avt, UPnPClient.avTransport, "Pause", ["InstanceID": "0"])
			case .play:
				_ = try await UPnPClient.call(avt, UPnPClient.avTransport, "Play", ["InstanceID": "0", "Speed": "1"])
			case .stop:
				// The last poll may be two seconds old: resume exactly where it stops.
				await refreshPosition(s)
				save(s)
				_ = try await UPnPClient.call(avt, UPnPClient.avTransport, "Stop", ["InstanceID": "0"])
				end(s, nil)
			case let .seek(ms):
				try await seek(s, max(ms, 0))
			case let .volume(v):
				guard let rc = s.dev.renderingControl else { throw TVError("Televize neumožňuje ovládat hlasitost.") }
				let v = min(max(v, 0), 100)
				_ = try await UPnPClient.call(rc, UPnPClient.renderingControl, "SetVolume",
				                              ["InstanceID": "0", "Channel": "Master", "DesiredVolume": String(v)])
				s.st.volume = v
			case let .mute(on):
				guard let rc = s.dev.renderingControl else { throw TVError("Televize neumožňuje ovládat hlasitost.") }
				_ = try await UPnPClient.call(rc, UPnPClient.renderingControl, "SetMute",
				                              ["InstanceID": "0", "Channel": "Master", "DesiredMute": on ? "1" : "0"])
				s.st.muted = on
			}
		} catch let e as TVError {
			throw e
		} catch {
			throw TVError("Televize příkaz odmítla: \(Self.describe(error))")
		}
	}
}
