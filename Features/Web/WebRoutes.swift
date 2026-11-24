import Foundation

/// The web interface: on the Mac itself (localhost) without login, from other devices with a password when allowed.
nonisolated struct WebRoutes: Sendable {
	static let cookie = "minordlna_session"
	/// Sent by the page with every POST; a cross-site form cannot set it.
	static let csrfHeader = HTTPHeaderName("X-MinorDLNA")

	let access: WebAccess
	let catalog: LibraryCatalog
	let tv: TVController
	let store: Store
	let transcoder: Transcoder
	let hls: HLSSessions
	/// A position saved by the web player: the TV library shows it.
	let positionSaved: @Sendable () -> Void
	let state: @Sendable () -> WebState

	struct WebState: Encodable {
		struct Lib: Encodable {
			var name: String
			var type: String
			var items: Int
		}
		var name: String
		var version: String
		var libraries: [Lib]
		/// Opened on the Mac itself; such a page has no logout.
		var local = false
	}

	enum Gate {
		/// The page shell and login, so a remote device can show the login form.
		case open
		case login
	}

	func register(_ r: Router) {
		r.get("/") { req in
			guard let denied = guarding(req, .open) else {
				return HTTPResponse(status: .ok, headers: [.contentType: "text/html; charset=utf-8", .cacheControl: "no-store"],
				                body: .data(Data((WebPage.index).utf8)))
			}
			return denied
		}
		r.post("/api/login") { req in
			if let denied = guarding(req, .open) { return denied }
			struct Body: Decodable { var password: String }
			let password = (try? JSONDecoder().decode(Body.self, from: req.body))?.password ?? ""
			let ip = req.remoteIP
			switch access.login(ip: ip, password: password) {
			case let .ok(token):
				AppLog.server.info("web login from \(ip, privacy: .public)")
				var res = json(["ok": true])
				res.headers[.setCookie] = "\(Self.cookie)=\(token); Path=/; Max-Age=\(Int(WebAccess.sessionTTL)); HttpOnly; SameSite=Strict"
				return res
			case .disabled: return error(.forbidden, "Přístup z jiných zařízení je vypnutý.")
			case .locked: return error(.tooManyRequests, "Příliš mnoho pokusů, zkuste to za minutu.")
			case .wrong:
				AppLog.server.warning("failed web login from \(ip, privacy: .public)")
				return error(.unauthorized, "Nesprávné heslo.")
			}
		}
		r.post("/api/logout") { req in
			if let denied = guarding(req, .open) { return denied }
			access.logout(Self.token(req))
			var res = json(["ok": true])
			res.headers[.setCookie] = "\(Self.cookie)=; Path=/; Max-Age=0; HttpOnly; SameSite=Strict"
			return res
		}
		r.get("/api/state") { req in
			if let denied = guarding(req, .login) { return denied }
			var s = state()
			s.local = Self.isLocal(req)
			return json(s)
		}
		registerLibrary(r)
		registerPlayer(r)
	}

	struct TVDevice: Encodable {
		var udn, name, maker, model, ip: String
		var online, canWake: Bool
	}

	private func registerLibrary(_ r: Router) {
		r.get("/api/browse") { req in
			if let denied = guarding(req, .login) { return denied }
			guard let page = try? catalog.page(req.query["id"] ?? "0") else { return error(.notFound, "Položka už neexistuje.") }
			return json(page)
		}
		r.get("/api/search") { req in
			if let denied = guarding(req, .login) { return denied }
			return json(["entries": catalog.search(req.query["q"] ?? "").map(BrowseEntry.init)])
		}
		r.get("/api/tv") { req in
			if let denied = guarding(req, .login) { return denied }
			return await tvState()
		}
		r.post("/api/tv/:action") { req in
			if let denied = guarding(req, .login) { return denied }
			struct Body: Decodable {
				var udn: String?
				var id: String?
				var fromStart: Bool?
				var command: String?
				var value: Int?
			}
			let b = (try? JSONDecoder().decode(Body.self, from: req.body)) ?? Body()
			do {
				switch req.parameters["action"] {
				case "search":
					_ = try await tv.search()
				case "wake":
					try await tv.wake(b.udn ?? "")
				case "play":
					let item = try? catalog.metadata(b.id ?? "")
					let from = b.fromStart == true || item?.watched == true ? 0 : item?.positionMs ?? 0
					try await tv.play(udn: b.udn ?? "", id: b.id ?? "", fromMs: from)
				case "command":
					let v = b.value ?? 0
					let c: TVCommand? = switch b.command {
					case "pause": .pause
					case "play": .play
					case "stop": .stop
					case "seek": .seek(ms: v)
					case "volume": .volume(v)
					case "mute": .mute(v != 0)
					default: nil
					}
					guard let c else { return error(.badRequest, "Neznámý příkaz.") }
					try await tv.command(c)
				default:
					return HTTPResponse(status: .notFound)
				}
			} catch {
				return self.error(.badRequest, "\(error)")
			}
			return await tvState()
		}
	}

	private func tvState() async -> HTTPResponse {
		struct State: Encodable {
			var devices: [TVDevice]
			var status: TVStatus?
		}
		let devices = await tv.devices().map {
			TVDevice(udn: $0.udn, name: $0.name, maker: $0.maker, model: $0.model, ip: $0.ip, online: $0.online, canWake: !$0.mac.isEmpty)
		}
		return json(State(devices: devices, status: await tv.status()))
	}

	/// nil lets the request through.
	func guarding(_ req: HTTPRequest, _ gate: Gate) -> HTTPResponse? {
		if req.method != .get, req.method != .head, req.headers[Self.csrfHeader] != "1" { return HTTPResponse(status: .forbidden) }
		if Self.isLocal(req) { return nil }
		guard access.enabled else {
			return HTTPResponse(status: .forbidden, headers: [.contentType: "text/plain; charset=utf-8"],
			                body: .data(Data(("Přístup z jiných zařízení je vypnutý. Zapněte ho v Nastavení aplikace MinorDLNA na Macu.").utf8)))
		}
		if gate == .open || access.valid(Self.token(req)) { return nil }
		return error(.unauthorized, "login")
	}

	static func isLocal(_ req: HTTPRequest) -> Bool { isLocal(ip: req.remoteIP, authority: req.authority) }

	/// Loopback, addressed by a loopback name: a DNS-rebound page reaches the server under its own host name.
	static func isLocal(ip: String?, authority: String?) -> Bool {
		guard let ip, ip == "127.0.0.1" || ip == "::1" || ip == "::ffff:127.0.0.1" else { return false }
		var host = authority ?? ""
		if host.hasPrefix("[") { host = String(host.dropFirst().prefix { $0 != "]" }) } else { host = String(host.prefix { $0 != ":" }) }
		return host == "localhost" || host == "127.0.0.1" || host == "::1"
	}

	static func token(_ req: HTTPRequest) -> String? {
		for field in req.headers[values: .cookie] {
			for pair in field.split(separator: ";") {
				let kv = pair.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
				if kv.count == 2, kv[0] == cookie { return String(kv[1]) }
			}
		}
		return nil
	}

	func json(_ v: some Encodable) -> HTTPResponse {
		let data = (try? JSONEncoder().encode(v)) ?? Data("{}".utf8)
		return HTTPResponse(status: .ok, headers: [.contentType: "application/json; charset=utf-8", .cacheControl: "no-store"],
		                body: .data(data))
	}

	func error(_ status: HTTPStatus, _ message: String) -> HTTPResponse {
		var r = json(["error": message])
		r.status = status
		return r
	}
}
