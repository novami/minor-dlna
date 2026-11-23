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
			if restartConfig(settings) != restartConfig(oldValue) {
				scheduleRestart()
			} else {
				if settings.transcode.clients != oldValue.transcode.clients {
					Task { [server, clients = settings.transcode.clients] in await server.chooseProfiles(clients) }
				}
				if settings.remote != oldValue.remote {
					Task { [server, remote = settings.remote] in await server.setRemote(remote) }
				}
			}
		}
	}
	private(set) var serverState: ServerState = .stopped
	/// Refreshed while the overview or settings window is open.
	private(set) var status: ServerStatus?
	private(set) var cacheSize: Int64?
	@ObservationIgnored private(set) var updates: UpdateModel!
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
		updates = UpdateModel(auto: { [weak self] in self?.settings.autoUpdate ?? false },
		                      busy: { [weak self] in await self?.server.status()?.transcodes.isEmpty == false })
	}

	private func serverConfig(_ s: Settings) -> ServerConfig {
		ServerConfig(settings: s, version: Self.version, iconURL: Bundle.main.url(forResource: "AppIcon", withExtension: "icns"))
	}

	/// Hand-picked client profiles and web access apply without a restart.
	private func restartConfig(_ s: Settings) -> ServerConfig {
		var s = s
		s.transcode.clients = [:]
		s.remote = .init()
		return serverConfig(s)
	}

	/// Polls the server status until the calling view goes away.
	func watchStatus() async {
		while !Task.isCancelled {
			status = await server.status()
			try? await Task.sleep(for: .seconds(2))
		}
	}

	func refreshCacheSize() async {
		cacheSize = await Task.detached { CacheStorage.size() }.value
	}

	func clearCache() async {
		do {
			try await server.clearCache()
		} catch {
			self.error = "Mezipaměť nešlo smazat: \(error.localizedDescription)"
		}
		await refreshCacheSize()
	}

	/// Hashing takes a moment (PBKDF2), so it runs off the main thread.
	func setPassword(_ password: String) async {
		let hash = await Task.detached { WebPassword.hash(password) }.value
		settings.remote.passwordHash = hash
	}

	var webURL: URL? { URL(string: "http://localhost:\(settings.port)/") }

	/// Addresses other devices open the web interface at.
	var remoteURLs: [String] {
		guard case let .running(port, addresses) = serverState else { return [] }
		return addresses.map { "http://\($0):\(port)/" }
	}

	// MARK: Metadata

	private(set) var metaEntries: [MetaEntry] = []

	func refreshMetadata() async { metaEntries = await server.metadataEntries() }

	func searchMetadata(_ id: Int64, _ query: String) async throws -> [MetaCandidate] {
		try await server.metadataSearch(id, query)
	}

	/// nil: no metadata for the title.
	func setMetadata(_ id: Int64, wikidata: String?) async throws {
		try await server.metadataSet(id, wikidata: wikidata)
		await refreshMetadata()
	}

	func rematchMetadata(_ id: Int64) async {
		do { try await server.metadataRematch(id) } catch { self.error = "Nešlo znovu vyhledat: \(error.localizedDescription)" }
		await refreshMetadata()
	}

	/// nil returns the client to automatic detection.
	func choose(profile: String?, for ip: String) {
		settings.transcode.clients[ip] = profile
	}

	/// Debounced, so typing the server name restarts the server once. Each restart waits for the previous one,
	/// so two servers never compete for the port.
	private func scheduleRestart(after delay: Duration = .milliseconds(800)) {
		let previous = restartTask
		previous?.cancel()
		restartTask = Task { [weak self, server] in
			await previous?.value
			try? await Task.sleep(for: delay)
			// Read now: web access and client profiles may have changed during the delay without a restart of their own.
			guard !Task.isCancelled, let self else { return }
			await server.start(serverConfig(settings))
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
