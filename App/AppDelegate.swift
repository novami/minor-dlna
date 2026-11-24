import AppKit

/// AppKit entry point for what SwiftUI does not cover: the app lives in the menu bar after its windows close.
final class AppDelegate: NSObject, NSApplicationDelegate {
	func applicationDidFinishLaunching(_ notification: Notification) {
		let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
		AppLog.app.info("Launched \(version, privacy: .public)")
	}

	func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
		false
	}
}
