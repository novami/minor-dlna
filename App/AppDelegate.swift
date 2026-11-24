import AppKit

/// AppKit entry point for what SwiftUI does not cover: the app lives in the menu bar after its windows close.
final class AppDelegate: NSObject, NSApplicationDelegate {
	func applicationDidFinishLaunching(_ notification: Notification) {
		let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
		AppLog.app.info("Launched \(version, privacy: .public)")
	}

	/// Stops the server before the app quits: SSDP says goodbye and ffmpeg processes end.
	static var shutdown: (@MainActor () async -> Void)?

	func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
		guard let shutdown = Self.shutdown else { return .terminateNow }
		Task { @MainActor in
			await shutdown()
			sender.reply(toApplicationShouldTerminate: true)
		}
		return .terminateLater
	}

	func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
		false
	}
}
