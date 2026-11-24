import Foundation
import Darwin

/// Announces the device on the LAN (NOTIFY) and answers M-SEARCH.
nonisolated final class SSDPService: BackgroundService {
	static let maxAge = 1800
	static let group = "239.255.255.250"

	let uuid: String
	let port: Int
	let serverHeader: String
	let services: [String]

	init(uuid: String, port: Int, serverHeader: String, services: [String]) {
		self.uuid = uuid
		self.port = port
		self.serverHeader = serverHeader
		self.services = services
	}

	/// Notification types with their USN.
	var targets: [(nt: String, usn: String)] {
		let u = "uuid:\(uuid)"
		return [("upnp:rootdevice", "\(u)::upnp:rootdevice"), (u, u), (Descriptions.deviceType, "\(u)::\(Descriptions.deviceType)")]
			+ services.map { ($0, "\(u)::\($0)") }
	}

	func matches(searchTarget st: String) -> [(nt: String, usn: String)] {
		st == "ssdp:all" ? targets : targets.filter { $0.nt == st }
	}

	/// Announces until cancelled, then says goodbye.
	func run() async {
		let socket: UDPSocket
		do { socket = try UDPSocket(port: 1900, reuse: true) } catch {
			AppLog.ssdp.error("cannot listen: \(error, privacy: .public)")
			return
		}
		await withTaskGroup(of: Void.self) { group in
			group.addTask { [self] in
				for await d in socket.datagrams() {
					guard let text = String(data: d.data, encoding: .utf8) else { continue }
					Task { await self.handleSearch(text, from: d, on: socket) }
				}
			}
			group.addTask { [self] in
				var joined = Set<String>()
				_ = join(socket, joined: &joined)
				for _ in 0..<3 { // UDP is lossy
					notify("ssdp:alive", on: socket)
					try? await Task.sleep(for: .milliseconds(200))
				}
				var sinceAlive = 0
				while !Task.isCancelled {
					try? await Task.sleep(for: .seconds(30))
					sinceAlive += 30
					if join(socket, joined: &joined) || sinceAlive >= Self.maxAge / 2 {
						notify("ssdp:alive", on: socket)
						sinceAlive = 0
					}
				}
			}
			// Both tasks end when the run is cancelled.
			await group.waitForAll()
		}
		notify("ssdp:byebye", on: socket)
		socket.close()
	}

	/// Joins the multicast group on interfaces that appeared since the last call. Reports whether any did.
	private func join(_ socket: UDPSocket, joined: inout Set<String>) -> Bool {
		var added = false
		for ifc in LANInterface.all() where !joined.contains(ifc.name) {
			do {
				try socket.joinGroup(Self.group, interface: ifc.address)
				joined.insert(ifc.name)
				added = true
				AppLog.ssdp.info("listening on \(ifc.name, privacy: .public)")
				AppLog.ssdp.debug("address \(ifc.ip, privacy: .private)")
			} catch {
				AppLog.ssdp.error("join \(ifc.name, privacy: .public): \(error, privacy: .public)")
			}
		}
		return added
	}

	private func notify(_ nts: String, on socket: UDPSocket) {
		for ifc in LANInterface.all() {
			do {
				try socket.setMulticastInterface(ifc.address)
				for t in targets {
					var msg = "NOTIFY * HTTP/1.1\r\nHOST: \(Self.group):1900\r\nNT: \(t.nt)\r\nNTS: \(nts)\r\nUSN: \(t.usn)\r\n"
					if nts == "ssdp:alive" {
						msg += "CACHE-CONTROL: max-age=\(Self.maxAge)\r\nLOCATION: \(location(ifc))\r\nSERVER: \(serverHeader)\r\n"
					}
					try socket.send(Data((msg + "\r\n").utf8), to: Self.group, port: 1900)
				}
			} catch {
				AppLog.ssdp.debug("notify on \(ifc.name, privacy: .public): \(error, privacy: .public)")
			}
		}
	}

	private func location(_ ifc: LANInterface) -> String { "http://\(ifc.ip):\(port)/description.xml" }

	private func handleSearch(_ text: String, from remote: Datagram, on socket: UDPSocket) async {
		guard let req = Self.parseSearch(text), let addr = LANInterface.parse(remote.ip),
		      let ifc = LANInterface.all().first(where: { $0.contains(addr) }) else { return }
		let found = matches(searchTarget: req.st)
		guard !found.isEmpty else { return }
		let replies = found.map { t in
			Self.searchReply(target: t, location: location(ifc), server: serverHeader)
		}
		// Replies are spread over MX seconds, so many devices do not answer at once.
		try? await Task.sleep(for: .milliseconds(Int.random(in: 0..<(min(max(req.mx, 1), 3) * 1000))))
		for r in replies { try? socket.send(Data(r.utf8), to: remote.ip, port: remote.port) }
	}

	static func searchReply(target t: (nt: String, usn: String), location: String, server: String) -> String {
		"HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=\(maxAge)\r\nDATE: \(httpDate.string(from: Date()))\r\nEXT:\r\n"
			+ "LOCATION: \(location)\r\nSERVER: \(server)\r\nST: \(t.nt)\r\nUSN: \(t.usn)\r\n\r\n"
	}

	/// Returns the search target and MX of an "M-SEARCH ... MAN: ssdp:discover" request.
	static func parseSearch(_ text: String) -> (st: String, mx: Int)? {
		let lines = text.components(separatedBy: "\r\n")
		guard lines.first?.hasPrefix("M-SEARCH ") == true else { return nil }
		var h: [String: String] = [:]
		for line in lines.dropFirst() {
			guard let colon = line.firstIndex(of: ":") else { continue }
			h[line[..<colon].trimmingCharacters(in: .whitespaces).uppercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
		}
		guard h["MAN"]?.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) == "ssdp:discover", let st = h["ST"] else { return nil }
		return (st, Int(h["MX"] ?? "") ?? 1)
	}
}

// DateFormatter is thread-safe since macOS 10.9.
nonisolated(unsafe) let httpDate: DateFormatter = {
	let f = DateFormatter()
	f.locale = Locale(identifier: "en_US_POSIX")
	f.timeZone = TimeZone(identifier: "GMT")
	f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
	return f
}()
