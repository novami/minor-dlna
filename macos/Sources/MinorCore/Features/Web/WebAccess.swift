import CommonCrypto
import Foundation
import Synchronization

/// Password-protected web access from other devices; the Mac itself (localhost) needs no login.
public struct RemoteSettings: Codable, Equatable, Sendable {
	public var enabled: Bool
	/// WebPassword.hash; empty means no password set, which keeps remote access off.
	public var passwordHash: String

	public init(enabled: Bool = false, passwordHash: String = "") {
		self.enabled = enabled
		self.passwordHash = passwordHash
	}

	public init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
		passwordHash = try c.decodeIfPresent(String.self, forKey: .passwordHash) ?? ""
	}

	public var active: Bool { enabled && !passwordHash.isEmpty }
}

/// PBKDF2-SHA256, stored as "pbkdf2-sha256$rounds$salt$hash" (base64).
public enum WebPassword {
	static let rounds: UInt32 = 210_000
	public static let minLength = 8

	public static func hash(_ password: String) -> String {
		var salt = [UInt8](repeating: 0, count: 16)
		_ = SecRandomCopyBytes(kSecRandomDefault, salt.count, &salt)
		let key = derive(password, salt: salt, rounds: rounds)
		return "pbkdf2-sha256$\(rounds)$\(Data(salt).base64EncodedString())$\(Data(key).base64EncodedString())"
	}

	public static func verify(_ password: String, against stored: String) -> Bool {
		let parts = stored.split(separator: "$")
		guard parts.count == 4, parts[0] == "pbkdf2-sha256", let rounds = UInt32(parts[1]), rounds > 0,
		      let salt = Data(base64Encoded: String(parts[2])), let want = Data(base64Encoded: String(parts[3])) else { return false }
		let got = derive(password, salt: [UInt8](salt), rounds: rounds)
		guard got.count == want.count else { return false }
		return zip(got, want).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0 // constant time
	}

	private static func derive(_ password: String, salt: [UInt8], rounds: UInt32) -> [UInt8] {
		var out = [UInt8](repeating: 0, count: 32)
		let pw = Array(password.utf8)
		pw.withUnsafeBufferPointer { p in
			p.withMemoryRebound(to: Int8.self) { pi in
				_ = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pi.baseAddress, pw.count, salt, salt.count,
				                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds, &out, out.count)
			}
		}
		return out
	}
}

/// Login sessions and brute-force protection. Lives as long as the app, so a server restart keeps users logged in.
public final class WebAccess: Sendable {
	static let sessionTTL: TimeInterval = 30 * 24 * 3600
	static let maxFailures = 5
	static let lockout: TimeInterval = 60

	enum Login: Equatable {
		case ok(token: String)
		case disabled, locked, wrong
	}

	private struct State {
		var settings = RemoteSettings()
		var tokens: [String: Date] = [:]
		var failures: [String: (count: Int, until: Date)] = [:]
	}
	private let state = Mutex(State())

	public init() {}

	/// A new password logs everybody out.
	public func configure(_ s: RemoteSettings) {
		state.withLock {
			if $0.settings.passwordHash != s.passwordHash || !s.active { $0.tokens = [:] }
			$0.settings = s
		}
	}

	var enabled: Bool { state.withLock { $0.settings.active } }

	func login(ip: String, password: String) -> Login {
		let (hash, locked) = state.withLock { s -> (String?, Bool) in
			guard s.settings.active else { return (nil, false) }
			if let f = s.failures[ip], f.count >= Self.maxFailures, Date() < f.until { return (nil, true) }
			return (s.settings.passwordHash, false)
		}
		if locked { return .locked }
		guard let hash else { return .disabled }
		let ok = WebPassword.verify(password, against: hash)
		return state.withLock { s in
			guard ok else {
				var f = s.failures[ip] ?? (0, .distantPast)
				if f.count >= Self.maxFailures { f.count = 0 } // the lockout has passed
				f.count += 1
				f.until = Date().addingTimeInterval(Self.lockout)
				s.failures[ip] = f
				if s.failures.count > 1000 { s.failures = s.failures.filter { $0.value.until > Date() } }
				return .wrong
			}
			s.failures[ip] = nil
			let now = Date()
			s.tokens = s.tokens.filter { $0.value > now }
			var bytes = [UInt8](repeating: 0, count: 32)
			_ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
			let token = bytes.map { String(format: "%02x", $0) }.joined()
			s.tokens[token] = now.addingTimeInterval(Self.sessionTTL)
			return .ok(token: token)
		}
	}

	func valid(_ token: String?) -> Bool {
		guard let token else { return false }
		return state.withLock { $0.settings.active && ($0.tokens[token].map { $0 > Date() } ?? false) }
	}

	func logout(_ token: String?) {
		guard let token else { return }
		_ = state.withLock { $0.tokens.removeValue(forKey: token) }
	}
}
