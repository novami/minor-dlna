import Foundation
import HTTPTypes
import Hummingbird
import NIOCore

/// The web interface: on the Mac itself (localhost) without login, from other devices with a password when allowed.
struct WebRoutes: Sendable {
	static let cookie = "minordlna_session"
	/// Sent by the page with every POST; a cross-site form cannot set it.
	static let csrfHeader = HTTPField.Name("X-MinorDLNA")!

	let access: WebAccess
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

	private enum Gate {
		/// The page shell and login, so a remote device can show the login form.
		case open
		case login
	}

	func register(_ r: Router<DLNAContext>) {
		r.get("/") { req, ctx in
			guard let denied = guarding(req, ctx, .open) else {
				return Response(status: .ok, headers: [.contentType: "text/html; charset=utf-8", .cacheControl: "no-store"],
				                body: .init(byteBuffer: ByteBuffer(string: WebPage.index)))
			}
			return denied
		}
		r.post("/api/login") { req, ctx in
			if let denied = guarding(req, ctx, .open) { return denied }
			struct Body: Decodable { var password: String }
			let data = try await req.body.collect(upTo: 4096)
			let password = (try? JSONDecoder().decode(Body.self, from: Data(data.readableBytesView)))?.password ?? ""
			let ip = ctx.remoteAddress?.ipAddress ?? ""
			switch access.login(ip: ip, password: password) {
			case let .ok(token):
				Log.server.info("web login from \(ip, privacy: .public)")
				var res = json(["ok": true])
				res.headers[.setCookie] = "\(Self.cookie)=\(token); Path=/; Max-Age=\(Int(WebAccess.sessionTTL)); HttpOnly; SameSite=Strict"
				return res
			case .disabled: return error(.forbidden, "Přístup z jiných zařízení je vypnutý.")
			case .locked: return error(.tooManyRequests, "Příliš mnoho pokusů, zkuste to za minutu.")
			case .wrong:
				Log.server.warning("failed web login from \(ip, privacy: .public)")
				return error(.unauthorized, "Nesprávné heslo.")
			}
		}
		r.post("/api/logout") { req, ctx in
			if let denied = guarding(req, ctx, .open) { return denied }
			access.logout(Self.token(req))
			var res = json(["ok": true])
			res.headers[.setCookie] = "\(Self.cookie)=; Path=/; Max-Age=0; HttpOnly; SameSite=Strict"
			return res
		}
		r.get("/api/state") { req, ctx in
			if let denied = guarding(req, ctx, .login) { return denied }
			var s = state()
			s.local = Self.isLocal(req, ctx)
			return json(s)
		}
	}

	/// nil lets the request through.
	private func guarding(_ req: Request, _ ctx: DLNAContext, _ gate: Gate) -> Response? {
		if req.method != .get, req.method != .head, req.headers[Self.csrfHeader] != "1" { return Response(status: .forbidden) }
		if Self.isLocal(req, ctx) { return nil }
		guard access.enabled else {
			return Response(status: .forbidden, headers: [.contentType: "text/plain; charset=utf-8"],
			                body: .init(byteBuffer: ByteBuffer(string: "Přístup z jiných zařízení je vypnutý. Zapněte ho v Nastavení aplikace MinorDLNA na Macu.")))
		}
		if gate == .open || access.valid(Self.token(req)) { return nil }
		return error(.unauthorized, "login")
	}

	static func isLocal(_ req: Request, _ ctx: DLNAContext) -> Bool { isLocal(ip: ctx.remoteAddress?.ipAddress, authority: req.head.authority) }

	/// Loopback, addressed by a loopback name: a DNS-rebound page reaches the server under its own host name.
	static func isLocal(ip: String?, authority: String?) -> Bool {
		guard let ip, ip == "127.0.0.1" || ip == "::1" || ip == "::ffff:127.0.0.1" else { return false }
		var host = authority ?? ""
		if host.hasPrefix("[") { host = String(host.dropFirst().prefix { $0 != "]" }) } else { host = String(host.prefix { $0 != ":" }) }
		return host == "localhost" || host == "127.0.0.1" || host == "::1"
	}

	static func token(_ req: Request) -> String? {
		for field in req.headers[values: .cookie] {
			for pair in field.split(separator: ";") {
				let kv = pair.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
				if kv.count == 2, kv[0] == cookie { return String(kv[1]) }
			}
		}
		return nil
	}

	private func json(_ v: some Encodable) -> Response {
		let data = (try? JSONEncoder().encode(v)) ?? Data("{}".utf8)
		return Response(status: .ok, headers: [.contentType: "application/json; charset=utf-8", .cacheControl: "no-store"],
		                body: .init(byteBuffer: ByteBuffer(bytes: data)))
	}

	private func error(_ status: HTTPResponse.Status, _ message: String) -> Response {
		var r = json(["error": message])
		r.status = status
		return r
	}
}
