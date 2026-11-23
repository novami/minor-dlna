import CryptoKit
import Foundation
import Testing
@testable import MinorCore

@Test func versions() throws {
	#expect(try #require(Version("v1.2.10")) > #require(Version("v1.2.9")))
	#expect(try #require(Version("v1.0.0")) > #require(Version("v1.0.0-rc.2")))
	#expect(try #require(Version("v1.0.0-rc.10")) > #require(Version("v1.0.0-rc.9")))
	#expect(Version("1.0.0") == nil && Version("v1.0") == nil && Version("vX.0.0") == nil)
	#expect(Version.base(of: "v0.2.3-28-gf876e73-dirty")?.description == "v0.2.3")
	#expect(Version.base(of: "dev") == nil)
}

@Test func releaseSignature() throws {
	// checksums.txt and its signature from the v0.2.3 release, signed by the pipeline.
	let sums = Data("a26b30fc3f8be225d96a91febe323be8ca7f03745f6bf7c7e7f4a37ac355a13f  MinorDLNA-v0.2.3-macos.zip\n".utf8)
	let sig = Data("EXxdQMtHxFinZ5xAOAXI8rCAwn6d3eJxRgKyKhv6uD6LYXT0p1yGCzZtOMAk0mjumoLyEV7SwcZuzbN5NYjsDQ==\n".utf8)
	#expect(Updater.verify(sums, signature: sig, publicKey: Updater.publicKey))
	#expect(!Updater.verify(sums + Data("x".utf8), signature: sig, publicKey: Updater.publicKey))
	#expect(Updater.checksum(in: sums, for: "MinorDLNA-v0.2.3-macos.zip") == "a26b30fc3f8be225d96a91febe323be8ca7f03745f6bf7c7e7f4a37ac355a13f")
	#expect(Updater.checksum(in: sums, for: "other.zip") == nil)

	let key = Curve25519.Signing.PrivateKey()
	let mine = try key.signature(for: sums).base64EncodedString()
	#expect(Updater.verify(sums, signature: Data(mine.utf8), publicKey: key.publicKey.rawRepresentation.base64EncodedString()))
}

@Test func displayVersion() {
	#expect(Version.display("v0.2.3-40-g29ecd9d-dirty") == "0.2.3")
	#expect(Version.display("v1.0.0-rc.1") == "1.0.0-rc.1")
	#expect(Version.display("dev") == "dev")
}
