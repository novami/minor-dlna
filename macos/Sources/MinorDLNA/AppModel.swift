import AppKit
import MinorCore
import Observation
import ServiceManagement

@MainActor @Observable
final class AppModel {
	var settings: Settings {
		didSet { if settings != oldValue { save() } }
	}
	/// Last error shown in the settings window.
	var error: String?

	init() {
		do {
			settings = try SettingsStore.load()
		} catch {
			// A damaged file is kept aside instead of being overwritten by the first change.
			let url = SettingsStore.defaultURL
			let bad = url.deletingPathExtension().appendingPathExtension("bad.json")
			try? FileManager.default.removeItem(at: bad)
			try? FileManager.default.moveItem(at: url, to: bad)
			Log.settings.error("settings unreadable, moved to \(bad.path, privacy: .public): \(error, privacy: .public)")
			settings = Settings()
			self.error = "Nastavení nešlo načíst, začíná se znovu. Původní soubor: \(bad.path)"
		}
		save() // persists the generated UUID and name on first launch
	}

	private func save() {
		do {
			try SettingsStore.save(settings)
		} catch {
			Log.settings.error("save failed: \(error, privacy: .public)")
			self.error = "Nastavení se nepodařilo uložit: \(error.localizedDescription)"
		}
	}

	var launchAtLogin: Bool {
		get {
			access(keyPath: \.launchAtLoginToken)
			return SMAppService.mainApp.status == .enabled
		}
		set {
			do {
				if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
			} catch {
				self.error = "Spouštění při přihlášení nešlo změnit: \(error.localizedDescription)"
			}
			withMutation(keyPath: \.launchAtLoginToken) { launchAtLoginToken += 1 }
		}
	}
	/// SMAppService is not observable; bumping this refreshes views that read launchAtLogin.
	private var launchAtLoginToken = 0

	func addFolders(_ urls: [URL], to libraryID: Library.ID?) {
		let used = Set(settings.libraries.flatMap(\.paths))
		let paths = urls.map(\.path).filter { !used.contains($0) }
		guard !paths.isEmpty else { return }
		if let i = settings.libraries.firstIndex(where: { $0.id == libraryID }) {
			settings.libraries[i].paths += paths
		} else {
			let name = URL(filePath: paths[0]).lastPathComponent
			settings.libraries.append(Library(name: name, type: .movies, paths: paths))
		}
	}
}

extension LibraryType {
	var label: String {
		switch self {
		case .movies: "Filmy"
		case .shows: "Seriály"
		case .videos: "Videa"
		case .photos: "Fotky"
		case .music: "Hudba"
		}
	}
}
