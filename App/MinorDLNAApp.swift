import AppKit
import SwiftUI

@main
struct MinorDLNAApp: App {
	@NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
	@State private var model = AppModel()

	var body: some Scene {
		MenuBarExtra("MinorDLNA", systemImage: "play.tv") {
			MenuContent().environment(model)
		}
		Window("MinorDLNA", id: "main") {
			MainView().environment(model)
				.task { model.updater.startAutomaticChecks() }
		}
		.defaultSize(width: 860, height: 640)
		SwiftUI.Settings {
			SettingsView().environment(model)
		}
	}
}

private struct MenuContent: View {
	@Environment(AppModel.self) private var model
	@Environment(\.openSettings) private var openSettings
	@Environment(\.openWindow) private var openWindow

	var body: some View {
		@Bindable var model = model
		Text(model.settings.name)
		Text(model.statusText)
		if case let .available(version, _) = model.updater.state {
			Button("Nainstalovat verzi \(version)") { Task { await model.updater.installUpdate() } }
		}
		if let st = model.tv.status, st.state != .stopped {
			Divider()
			Text("\(st.state == .paused ? "Pozastaveno" : "Hraje") na \(st.tv): \(st.title)")
			Button(st.state == .playing ? "Pozastavit" : "Pokračovat") { Task { await model.tv.command(st.state == .playing ? .pause : .play) } }
			Button("Zastavit") { Task { await model.tv.command(.stop) } }
		}
		Divider()
		Button("Otevřít MinorDLNA…") {
			NSApp.activate()
			openWindow(id: "main")
		}
		Button("Otevřít webové rozhraní") {
			if let url = model.webURL { NSWorkspace.shared.open(url) }
		}
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
