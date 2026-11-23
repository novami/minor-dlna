import Darwin
import Foundation
import NIOCore
import NIOPosix
import Synchronization

enum Discovery {
	static let localNetworkDenied = TVError(
		"macOS blokuje přístup k místní síti – povolte MinorDLNA v Nastavení systému → Soukromí a zabezpečení → Místní síť.")

	/// Sends M-SEARCH for renderers on every LAN interface and returns the description URLs that answer within wait.
	static func search(wait: Duration) async throws -> Set<String> {
		let found = Mutex(Set<String>())
		let channel = try await DatagramBootstrap(group: MultiThreadedEventLoopGroup.singleton)
			.channelInitializer { ch in
				ch.eventLoop.makeCompletedFuture {
					try ch.pipeline.syncOperations.addHandler(DatagramText { text, _ in
						if let loc = location(text) { found.withLock { _ = $0.insert(loc) } }
					})
				}
			}
			.bind(host: "0.0.0.0", port: 0).get()
		defer { channel.close(promise: nil) }
		let msg = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: \(UPnPClient.rendererType)1\r\n\r\n"
		let dest = try SocketAddress(ipAddress: SSDPService.group, port: 1900)
		var sent = false, failed = false
		for ifc in LANInterface.all() {
			do {
				try await (channel as! SocketOptionProvider).setIPMulticastIF(in_addr(s_addr: ifc.address)).get()
				for _ in 0..<2 { // UDP may drop one
					try await channel.writeAndFlush(AddressedEnvelope(remoteAddress: dest, data: ByteBuffer(string: msg)))
				}
				sent = true
			} catch {
				Log.ssdp.debug("search on \(ifc.name, privacy: .public): \(error, privacy: .public)")
				failed = true
			}
		}
		// An interface is up but sending fails: macOS denies the app its local network permission.
		if !sent { throw failed ? localNetworkDenied : TVError("Mac není připojený k místní síti.") }
		try await Task.sleep(for: wait)
		return found.withLock { $0 }
	}

	/// LOCATION of a search response.
	static func location(_ text: String) -> String? {
		let lines = text.components(separatedBy: "\r\n")
		guard lines.first?.hasPrefix("HTTP/1.1 200") == true else { return nil }
		for line in lines.dropFirst() {
			guard let colon = line.firstIndex(of: ":"), line[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == "location" else { continue }
			let v = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
			return v.isEmpty ? nil : v
		}
		return nil
	}

	/// Sends a Wake-on-LAN magic packet to the global broadcast and the broadcast of every LAN interface.
	static func wake(mac: String) async throws {
		let bytes = mac.split(whereSeparator: { $0 == ":" || $0 == "-" }).compactMap { UInt8($0, radix: 16) }
		guard bytes.count == 6 else { throw TVError("Neplatná MAC adresa televize.") }
		let packet = [UInt8](repeating: 0xFF, count: 6) + Array([[UInt8]](repeating: bytes, count: 16).joined())
		let channel = try await DatagramBootstrap(group: MultiThreadedEventLoopGroup.singleton)
			.channelOption(.socketOption(.so_broadcast), value: 1)
			.bind(host: "0.0.0.0", port: 0).get()
		defer { channel.close(promise: nil) }
		let targets = ["255.255.255.255"] + LANInterface.all().map { LANInterface.format($0.address | ~$0.netmask) }
		var sent = false
		for ip in Set(targets) {
			for port in [9, 7] {
				guard let addr = try? SocketAddress(ipAddress: ip, port: port) else { continue }
				if (try? await channel.writeAndFlush(AddressedEnvelope(remoteAddress: addr, data: ByteBuffer(bytes: packet)))) != nil { sent = true }
			}
		}
		if !sent { throw localNetworkDenied }
	}

	/// Hardware address of ip from the kernel ARP table (filled by talking to the TV), read in-process:
	/// macOS hides the table from an arp child process of an app without local network access.
	static func mac(of ip: String) -> String {
		guard let want = LANInterface.parse(ip) else { return "" }
		var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_DUMP, 0]
		var len = 0
		guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else { return "" }
		var buf = [UInt8](repeating: 0, count: len)
		guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return "" }
		return buf.withUnsafeBytes { raw in
			var off = 0
			while off + MemoryLayout<rt_msghdr>.size <= len {
				let hdr = raw.loadUnaligned(fromByteOffset: off, as: rt_msghdr.self)
				defer { off += Int(hdr.rtm_msglen) }
				guard hdr.rtm_msglen > 0 else { break }
				let sinOff = off + MemoryLayout<rt_msghdr>.size
				let sin = raw.loadUnaligned(fromByteOffset: sinOff, as: sockaddr_in.self)
				guard sin.sin_addr.s_addr == want else { continue }
				// Destination, then the gateway: a link address for ARP entries. Socket addresses are padded to 4 bytes.
				let dlOff = sinOff + (max(Int(sin.sin_len), 1) + 3) & ~3
				guard dlOff + MemoryLayout<sockaddr_dl>.size <= off + Int(hdr.rtm_msglen) else { continue }
				let dl = raw.loadUnaligned(fromByteOffset: dlOff, as: sockaddr_dl.self)
				guard dl.sdl_alen == 6 else { continue }
				let start = dlOff + MemoryLayout.offset(of: \sockaddr_dl.sdl_data)! + Int(dl.sdl_nlen)
				return (0..<6).map { String(format: "%02x", raw[start + $0]) }.joined(separator: ":")
			}
			return ""
		}
	}
}

/// Passes each received datagram on as text.
final class DatagramText: ChannelInboundHandler, Sendable {
	typealias InboundIn = AddressedEnvelope<ByteBuffer>
	let onText: @Sendable (String, SocketAddress) -> Void

	init(_ onText: @escaping @Sendable (String, SocketAddress) -> Void) { self.onText = onText }

	func channelRead(context: ChannelHandlerContext, data: NIOAny) {
		let env = unwrapInboundIn(data)
		onText(String(buffer: env.data), env.remoteAddress)
	}
}
