// swift-tools-version: 6.0
import PackageDescription

let package = Package(
	name: "MinorDLNA",
	platforms: [.macOS(.v15)],
	targets: [
		.target(name: "MinorCore"),
		.executableTarget(name: "MinorDLNA", dependencies: ["MinorCore"]),
		.testTarget(name: "MinorCoreTests", dependencies: ["MinorCore"]),
	]
)
