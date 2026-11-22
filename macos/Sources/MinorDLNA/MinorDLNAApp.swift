import AppKit
import MinorCore
import SwiftUI

@main
struct MinorDLNAApp: App {
	@State private var model = AppModel()

	var body: some Scene {
		MenuBarExtra("MinorDLNA", systemImage: "play.tv") {
			MenuContent().environment(model)
		}
		Settings {
			SettingsView().environment(model)
		}
	}
}

private struct MenuContent: View {
	@Environment(AppModel.self) private var model
	@Environment(\.openSettings) private var openSettings

	var body: some View {
		@Bindable var model = model
		Text(model.settings.name)
		Text("Server nespuštěn")
		Text("Verze \(Bundle.main.object(forInfoDictionaryKey: "MinorDLNABuild") as? String ?? "dev")")
		Divider()
		Button("Nastavení…") {
			// A menu bar app is never active on its own, so the window would open behind others.
			NSApp.activate()
			openSettings()
		}
		.keyboardShortcut(",")
		Toggle("Spouštět při přihlášení", isOn: $model.launchAtLogin)
		Divider()
		Button("Ukončit MinorDLNA") { NSApp.terminate(nil) }
			.keyboardShortcut("q")
	}
}
