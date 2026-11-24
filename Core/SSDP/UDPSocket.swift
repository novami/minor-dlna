import Darwin
import Foundation

nonisolated struct Datagram: Sendable {
	var data: Data
	var ip: String
	var port: UInt16
}

/// A UDP socket on plain BSD calls. SSDP multicast uses it because Network.framework delivers no multicast
/// datagrams to an app without Apple's multicast entitlement (checked on macOS 26: the group joins, nothing arrives).
nonisolated final class UDPSocket: Sendable {
	struct SocketError: Error, CustomStringConvertible {
		var call: String
		var code: Int32
		var description: String { "\(call): \(String(cString: strerror(code)))" }
	}

	let fd: Int32

	/// Binds 0.0.0.0:port; port 0 picks a free one.
	init(port: UInt16 = 0, reuse: Bool = false, broadcast: Bool = false) throws {
		fd = socket(AF_INET, SOCK_DGRAM, 0)
		guard fd >= 0 else { throw SocketError(call: "socket", code: errno) }
		var on: Int32 = 1
		if reuse {
			setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
			setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &on, socklen_t(MemoryLayout<Int32>.size))
		}
		if broadcast { setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size)) }
		var ttl: UInt8 = 2
		setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, 1)
		var loop: UInt8 = 1
		setsockopt(fd, IPPROTO_IP, IP_MULTICAST_LOOP, &loop, 1)
		var addr = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET), sin_port: port.bigEndian,
		                       sin_addr: in_addr(s_addr: INADDR_ANY), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
		let rc = withUnsafePointer(to: &addr) {
			$0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
		}
		guard rc == 0 else {
			let e = errno
			Darwin.close(fd)
			throw SocketError(call: "bind", code: e)
		}
	}

	func close() { Darwin.close(fd) }

	func joinGroup(_ group: String, interface: in_addr_t) throws {
		var mreq = ip_mreq(imr_multiaddr: in_addr(s_addr: LANInterface.parse(group) ?? 0), imr_interface: in_addr(s_addr: interface))
		guard setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &mreq, socklen_t(MemoryLayout<ip_mreq>.size)) == 0 else {
			throw SocketError(call: "join", code: errno)
		}
	}

	func setMulticastInterface(_ address: in_addr_t) throws {
		var a = in_addr(s_addr: address)
		guard setsockopt(fd, IPPROTO_IP, IP_MULTICAST_IF, &a, socklen_t(MemoryLayout<in_addr>.size)) == 0 else {
			throw SocketError(call: "multicast interface", code: errno)
		}
	}

	func send(_ data: Data, to ip: String, port: UInt16) throws {
		guard let target = LANInterface.parse(ip) else { throw SocketError(call: "address", code: EINVAL) }
		var addr = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET), sin_port: port.bigEndian,
		                       sin_addr: in_addr(s_addr: target), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
		let n = data.withUnsafeBytes { raw in
			withUnsafePointer(to: &addr) {
				$0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
					sendto(fd, raw.baseAddress, raw.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
				}
			}
		}
		guard n == data.count else { throw SocketError(call: "send", code: errno) }
	}

	/// Received datagrams until the consumer stops. Call close() afterwards.
	func datagrams() -> AsyncStream<Datagram> {
		AsyncStream { continuation in
			let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "udp.\(fd)"))
			let fd = fd
			source.setEventHandler {
				var buf = [UInt8](repeating: 0, count: 4096)
				var from = sockaddr_in()
				var len = socklen_t(MemoryLayout<sockaddr_in>.size)
				let n = withUnsafeMutablePointer(to: &from) {
					$0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &len) }
				}
				guard n > 0 else { return }
				continuation.yield(Datagram(data: Data(buf[0..<n]), ip: LANInterface.format(from.sin_addr.s_addr), port: UInt16(bigEndian: from.sin_port)))
			}
			continuation.onTermination = { _ in source.cancel() }
			source.resume()
		}
	}
}
