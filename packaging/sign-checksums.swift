// Signs a file with the release key: writes <file>.sig, base64 Ed25519.
// Key: base64 32-byte seed in MINORDLNA_SIGNING_KEY, or a file given as the second argument.
import CryptoKit
import Foundation

let args = CommandLine.arguments.dropFirst()
guard let path = args.first else {
	FileHandle.standardError.write(Data("usage: swift packaging/sign-checksums.swift <file> [key-file]\n".utf8))
	exit(2)
}
let encoded = args.count > 1 ? (try? String(contentsOfFile: args[args.startIndex + 1], encoding: .utf8)) : ProcessInfo.processInfo.environment["MINORDLNA_SIGNING_KEY"]
guard let seed = Data(base64Encoded: (encoded ?? "").trimmingCharacters(in: .whitespacesAndNewlines)), seed.count == 32,
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) else {
	FileHandle.standardError.write(Data("error: invalid or missing signing key\n".utf8))
	exit(1)
}
do {
	let sig = try key.signature(for: Data(contentsOf: URL(filePath: path)))
	try Data((sig.base64EncodedString() + "\n").utf8).write(to: URL(filePath: path + ".sig"))
} catch {
	FileHandle.standardError.write(Data("error: \(error)\n".utf8))
	exit(1)
}
