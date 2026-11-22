import AppKit
import MinorCore
import Observation
import ServiceManagement

@MainActor @Observable
final class AppModel {
	var settings: Settings {
		didSet {
			guard settings != oldValue else { return }
			save()
			if serverConfig(settings) != serverConfig(oldValue) { scheduleRestart() }
		}
	}
	private(set) var serverState: ServerState = .stopped
	@ObservationIgnored private let server = MediaServer()
	@ObservationIgnored private var restartTask: Task<Void, Never>?

	static let version = Bundle.main.object(forInfoDictionaryKey: "MinorDLNABuild") as? String ?? "dev"

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
		Task { [weak self, states = server.states] in
			for await state in states { self?.serverState = state }
		}
		scheduleRestart(after: .zero)
	}

	private func serverConfig(_ s: Settings) -> ServerConfig {
		ServerConfig(settings: s, version: Self.version, iconURL: Bundle.main.url(forResource: "AppIcon", withExtension: "icns"))
	}

	/// Debounced, so typing the server name restarts the server once. Each restart waits for the previous one,
	/// so two servers never compete for the port.
	private func scheduleRestart(after delay: Duration = .milliseconds(800)) {
		let previous = restartTask
		previous?.cancel()
		let config = serverConfig(settings)
		restartTask = Task { [server] in
			await previous?.value
			try? await Task.sleep(for: delay)
			guard !Task.isCancelled else { return }
			await server.start(config)
		}
	}

	var statusText: String {
		switch serverState {
		case .stopped: "Server nespuštěn"
		case .starting: "Server se spouští…"
		case let .running(port, addresses):
			addresses.isEmpty ? "Server běží, ale není připojen k síti" : "Server běží na \(addresses.map { "\($0):\(port)" }.joined(separator: ", "))"
		case let .failed(message): message
		}
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
