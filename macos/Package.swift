// swift-tools-version: 6.0
import PackageDescription

let package = Package(
	name: "MinorDLNA",
	platforms: [.macOS(.v15)],
	dependencies: [
		.package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
		.package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
		.package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.6.0"),
		.package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
		.package(url: "https://github.com/apple/swift-http-types.git", from: "1.0.0"),
	],
	targets: [
		.target(name: "MinorCore", dependencies: [
			.product(name: "Hummingbird", package: "hummingbird"),
			.product(name: "NIOCore", package: "swift-nio"),
			.product(name: "NIOPosix", package: "swift-nio"),
			.product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
			.product(name: "Logging", package: "swift-log"),
			.product(name: "HTTPTypes", package: "swift-http-types"),
		]),
		.executableTarget(name: "MinorDLNA", dependencies: ["MinorCore"]),
		.testTarget(name: "MinorCoreTests", dependencies: [
			"MinorCore",
			.product(name: "HummingbirdTesting", package: "hummingbird"),
		]),
	]
)
