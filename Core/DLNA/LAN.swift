import Darwin
import Foundation

/// An IPv4 LAN interface the server announces itself on.
nonisolated struct LANInterface: Sendable, Equatable {
	let name: String
	let index: UInt32
	let address: in_addr_t // network byte order
	let netmask: in_addr_t

	var ip: String { Self.format(address) }

	func contains(_ other: in_addr_t) -> Bool { address & netmask == other & netmask }

	/// Up, multicast-capable IPv4 interfaces, without loopback and virtual links (VPN, bridges, Apple peer-to-peer).
	static func all() -> [LANInterface] {
		var head: UnsafeMutablePointer<ifaddrs>?
		guard getifaddrs(&head) == 0, let first = head else { return [] }
		defer { freeifaddrs(head) }
		var out: [LANInterface] = []
		for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
			let ifa = p.pointee
			let flags = Int32(ifa.ifa_flags)
			guard flags & IFF_UP != 0, flags & IFF_MULTICAST != 0, flags & IFF_LOOPBACK == 0,
			      let addr = ifa.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET), let mask = ifa.ifa_netmask else { continue }
			let name = String(cString: ifa.ifa_name)
			let virtualPrefixes = ["utun", "bridge", "awdl", "llw", "anpi", "gif", "stf", "ap", "vmenet", "docker", "veth"]
			if virtualPrefixes.contains(where: name.hasPrefix) { continue }
			let a = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
			let m = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
			out.append(LANInterface(name: name, index: if_nametoindex(ifa.ifa_name), address: a, netmask: m))
		}
		return out
	}

	static func format(_ a: in_addr_t) -> String {
		var addr = in_addr(s_addr: a)
		var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
		inet_ntop(AF_INET, &addr, &buf, socklen_t(buf.count))
		return String(cString: buf)
	}

	static func parse(_ s: String) -> in_addr_t? {
		var addr = in_addr()
		return inet_pton(AF_INET, s, &addr) == 1 ? addr.s_addr : nil
	}
}

nonisolated enum AccessPolicy {
	/// Only private, link-local and loopback addresses may talk to the server.
	static func allows(_ ip: String) -> Bool {
		let v4 = ip.hasPrefix("::ffff:") ? String(ip.dropFirst(7)) : ip
		if let a = LANInterface.parse(v4) {
			let h = UInt32(bigEndian: a)
			let b1 = h >> 24, b2 = (h >> 16) & 0xFF
			return b1 == 10 || b1 == 127 || (b1 == 172 && (16...31).contains(b2)) || (b1 == 192 && b2 == 168) || (b1 == 169 && b2 == 254)
		}
		let l = ip.lowercased()
		return l == "::1" || l.hasPrefix("fe80:") || l.hasPrefix("fc") || l.hasPrefix("fd")
	}
}
