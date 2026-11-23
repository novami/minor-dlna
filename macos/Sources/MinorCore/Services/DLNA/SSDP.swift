import Foundation
import NIOCore
import NIOPosix
import ServiceLifecycle

/// Announces the device on the LAN (NOTIFY) and answers M-SEARCH. Plain BSD sockets through NIO,
/// because Network.framework multicast needs an entitlement Apple has to grant.
final class SSDPService: Service, Sendable {
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

	func run() async throws {
		let channel = try await DatagramBootstrap(group: MultiThreadedEventLoopGroup.singleton)
			.channelOption(.socketOption(.so_reuseaddr), value: 1)
			.channelOption(.socketOption(.so_reuseport), value: 1)
			.channelInitializer { [weak self] ch in
				ch.eventLoop.makeCompletedFuture {
					try ch.pipeline.syncOperations.addHandler(SearchHandler { text, remote in
						self?.handleSearch(text, from: remote, on: ch)
					})
				}
			}
			.bind(host: "0.0.0.0", port: 1900).get()
		let provider = channel as! SocketOptionProvider
		try await provider.setIPMulticastTTL(2).get()
		try await provider.setIPMulticastLoop(1).get()

		do {
			try await cancelWhenGracefulShutdown {
				var joined = Set<String>()
				_ = await self.join(channel, joined: &joined)
				for _ in 0..<3 { // UDP is lossy
					await self.notify("ssdp:alive", on: channel)
					try await Task.sleep(for: .milliseconds(200))
				}
				var sinceAlive = 0
				while true {
					try await Task.sleep(for: .seconds(30))
					sinceAlive += 30
					if await self.join(channel, joined: &joined) || sinceAlive >= Self.maxAge / 2 {
						await self.notify("ssdp:alive", on: channel)
						sinceAlive = 0
					}
				}
			}
		} catch is CancellationError {}
		await notify("ssdp:byebye", on: channel)
		try? await channel.close()
	}

	/// Joins the multicast group on interfaces that appeared since the last call. Reports whether any did.
	private func join(_ channel: any Channel, joined: inout Set<String>) async -> Bool {
		let devices = (try? System.enumerateDevices()) ?? []
		var added = false
		for ifc in LANInterface.all() where !joined.contains(ifc.name) {
			guard let dev = devices.first(where: { $0.name == ifc.name && $0.address?.protocol == .inet }) else { continue }
			do {
				try await (channel as! MulticastChannel).joinGroup(try SocketAddress(ipAddress: Self.group, port: 1900), device: dev).get()
				joined.insert(ifc.name)
				added = true
				Log.ssdp.info("listening on \(ifc.name, privacy: .public) \(ifc.ip, privacy: .public)")
			} catch {
				Log.ssdp.error("join \(ifc.name, privacy: .public): \(error, privacy: .public)")
			}
		}
		return added
	}

	private func notify(_ nts: String, on channel: any Channel) async {
		guard let dest = try? SocketAddress(ipAddress: Self.group, port: 1900) else { return }
		for ifc in LANInterface.all() {
			do {
				try await (channel as! SocketOptionProvider).setIPMulticastIF(in_addr(s_addr: ifc.address)).get()
				for t in targets {
					var msg = "NOTIFY * HTTP/1.1\r\nHOST: \(Self.group):1900\r\nNT: \(t.nt)\r\nNTS: \(nts)\r\nUSN: \(t.usn)\r\n"
					if nts == "ssdp:alive" {
						msg += "CACHE-CONTROL: max-age=\(Self.maxAge)\r\nLOCATION: \(location(ifc))\r\nSERVER: \(serverHeader)\r\n"
					}
					try await channel.writeAndFlush(AddressedEnvelope(remoteAddress: dest, data: ByteBuffer(string: msg + "\r\n")))
				}
			} catch {
				Log.ssdp.debug("notify on \(ifc.name, privacy: .public): \(error, privacy: .public)")
			}
		}
	}

	private func location(_ ifc: LANInterface) -> String { "http://\(ifc.ip):\(port)/description.xml" }

	private func handleSearch(_ text: String, from remote: SocketAddress, on channel: any Channel) {
		guard let req = Self.parseSearch(text), let ip = remote.ipAddress, let addr = LANInterface.parse(ip),
		      let ifc = LANInterface.all().first(where: { $0.contains(addr) }) else { return }
		let found = matches(searchTarget: req.st)
		guard !found.isEmpty else { return }
		let replies = found.map { t in
			"HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=\(Self.maxAge)\r\nDATE: \(httpDate.string(from: Date()))\r\nEXT:\r\n"
				+ "LOCATION: \(location(ifc))\r\nSERVER: \(serverHeader)\r\nST: \(t.nt)\r\nUSN: \(t.usn)\r\n\r\n"
		}
		let delay = Int.random(in: 0..<(min(max(req.mx, 1), 3) * 1000))
		channel.eventLoop.scheduleTask(in: .milliseconds(Int64(delay))) {
			for r in replies {
				channel.writeAndFlush(AddressedEnvelope(remoteAddress: remote, data: ByteBuffer(string: r)), promise: nil)
			}
		}
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

private final class SearchHandler: ChannelInboundHandler {
	typealias InboundIn = AddressedEnvelope<ByteBuffer>
	let onSearch: (String, SocketAddress) -> Void

	init(onSearch: @escaping (String, SocketAddress) -> Void) { self.onSearch = onSearch }

	func channelRead(context: ChannelHandlerContext, data: NIOAny) {
		var env = unwrapInboundIn(data)
		if let text = env.data.readString(length: env.data.readableBytes) { onSearch(text, env.remoteAddress) }
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
