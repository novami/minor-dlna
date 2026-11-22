import Foundation

/// GENA subscriptions of one service; sends evented state variables to subscribers.
actor Eventer {
	static let maxTimeout = 1800

	private struct Subscription {
		var urls: [URL]
		var seq: UInt32 = 0
		var expires: Date
	}

	enum Outcome: Equatable {
		case ok(sid: String, timeout: Int)
		case preconditionFailed
	}

	private let properties: @Sendable () -> [(String, String)]
	private var subs: [String: Subscription] = [:]
	private let session: URLSession = {
		let c = URLSessionConfiguration.ephemeral
		c.timeoutIntervalForRequest = 5
		return URLSession(configuration: c)
	}()

	init(properties: @escaping @Sendable () -> [(String, String)]) { self.properties = properties }

	func subscribe(remoteIP: String, sid: String?, nt: String?, callback: String?, timeout: String?) -> Outcome {
		var secs = Self.maxTimeout
		if let t = timeout?.lowercased(), t.hasPrefix("second-"), let n = Int(t.dropFirst(7)), n > 0 { secs = min(n, Self.maxTimeout) }
		let expires = Date().addingTimeInterval(TimeInterval(secs))
		if let sid { // renewal
			guard subs[sid] != nil else { return .preconditionFailed }
			subs[sid]?.expires = expires
			return .ok(sid: sid, timeout: secs)
		}
		guard nt == "upnp:event" else { return .preconditionFailed }
		// Only call back the subscriber itself, never a third host.
		let urls = (callback ?? "").split(separator: "<").compactMap { part -> URL? in
			guard let end = part.firstIndex(of: ">"), let u = URL(string: String(part[..<end])),
			      u.scheme == "http", u.host() == remoteIP else { return nil }
			return u
		}
		guard !urls.isEmpty else { return .preconditionFailed }
		expire()
		let sid = "uuid:\(UUID().uuidString.lowercased())"
		subs[sid] = Subscription(urls: Array(urls.prefix(4)), expires: expires)
		// The initial event must follow the SUBSCRIBE response.
		Task {
			try? await Task.sleep(for: .milliseconds(200))
			await self.send(sid)
		}
		return .ok(sid: sid, timeout: secs)
	}

	func unsubscribe(sid: String?) -> Bool {
		guard let sid else { return false }
		return subs.removeValue(forKey: sid) != nil
	}

	func notifyAll() {
		expire()
		for sid in subs.keys { Task { await send(sid) } }
	}

	private func expire() {
		let now = Date()
		subs = subs.filter { $0.value.expires > now }
	}

	private func send(_ sid: String) async {
		guard var sub = subs[sid] else { return }
		let seq = sub.seq
		sub.seq = sub.seq == .max ? 1 : sub.seq + 1 // wraps to 1, 0 is reserved for the initial event
		subs[sid] = sub

		var body = #"<?xml version="1.0" encoding="utf-8"?><e:propertyset xmlns:e="urn:schemas-upnp-org:event-1-0">"#
		for (name, value) in properties() { body += "<e:property><\(name)>\(value.xmlEscaped)</\(name)></e:property>" }
		body += "</e:propertyset>"

		for url in sub.urls {
			var req = URLRequest(url: url)
			req.httpMethod = "NOTIFY"
			req.httpBody = Data(body.utf8)
			req.setValue(#"text/xml; charset="utf-8""#, forHTTPHeaderField: "Content-Type")
			req.setValue("upnp:event", forHTTPHeaderField: "NT")
			req.setValue("upnp:propchange", forHTTPHeaderField: "NTS")
			req.setValue(sid, forHTTPHeaderField: "SID")
			req.setValue(String(seq), forHTTPHeaderField: "SEQ")
			if (try? await session.data(for: req)) != nil { return } // first URL that accepts wins
		}
	}
}
