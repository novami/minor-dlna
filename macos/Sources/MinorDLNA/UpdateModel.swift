import AppKit
import MinorCore
import Observation

/// Checks GitHub Releases daily, installs automatically when allowed and nothing is being transcoded,
/// and relaunches into the new version; a version that does not stay running is replaced by the previous one.
@MainActor @Observable
final class UpdateModel {
	enum Phase: Equatable {
		case idle
		case checking
		case upToDate
		case available(Release)
		case installing(String)
		case failed(String)
	}

	private(set) var phase = Phase.idle
	@ObservationIgnored private let updater = Updater()
	@ObservationIgnored private let auto: @MainActor () -> Bool
	@ObservationIgnored private let busy: @MainActor () async -> Bool

	static let checkEvery = Duration.seconds(24 * 3600)
	static let retryBusy = Duration.seconds(15 * 60)
	/// After this long the new version counts as working and the previous one is deleted.
	static let confirmAfter = Duration.seconds(60)

	private static var marker: URL { AppPaths.support.appending(path: "update-pending") }
	private var app: URL { Bundle.main.bundleURL }

	/// Release builds inside an app bundle; a development build only shows what is available.
	var installable: Bool { app.pathExtension == "app" && Version.base(of: AppModel.version) != nil }

	init(auto: @escaping @MainActor () -> Bool, busy: @escaping @MainActor () async -> Bool) {
		self.auto = auto
		self.busy = busy
		Task { await self.confirmPending() }
		Task { await self.loop() }
	}

	private func confirmPending() async {
		guard FileManager.default.fileExists(atPath: Self.marker.path) else { return }
		try? await Task.sleep(for: Self.confirmAfter)
		try? FileManager.default.removeItem(at: Self.marker)
		try? FileManager.default.removeItem(at: Updater.previous(of: app))
		Log.app.info("update to \(AppModel.version, privacy: .public) confirmed")
	}

	private func loop() async {
		guard installable else { return }
		try? await Task.sleep(for: .seconds(60))
		while !Task.isCancelled {
			var next = Self.checkEvery
			await check()
			if case let .available(rel) = phase, auto() {
				if await busy() {
					Log.app.info("update \(rel.version, privacy: .public) postponed, transcoding in progress")
					next = Self.retryBusy
				} else {
					await install(rel)
				}
			}
			try? await Task.sleep(for: next)
		}
	}

	func check() async {
		guard phase != .checking, !isInstalling else { return }
		phase = .checking
		do {
			let rel = try await updater.latest(current: AppModel.version)
			phase = rel.map(Phase.available) ?? .upToDate
		} catch {
			Log.app.error("update check failed: \(error, privacy: .public)")
			phase = .failed("Aktualizace nešlo zjistit: \(error.localizedDescription)")
		}
	}

	private var isInstalling: Bool { if case .installing = phase { true } else { false } }

	func install(_ rel: Release) async {
		guard installable, !isInstalling else { return }
		phase = .installing(rel.version)
		let (updater, app) = (updater, app)
		do {
			try await Task.detached { try await updater.install(rel, at: app) }.value
		} catch {
			Log.app.error("update to \(rel.version, privacy: .public) failed: \(error, privacy: .public)")
			phase = .failed("Aktualizace na \(rel.version) selhala: \(error.localizedDescription)")
			return
		}
		Log.app.info("update \(rel.version, privacy: .public) installed, relaunching")
		try? Data(rel.version.utf8).write(to: Self.marker)
		relaunch()
	}

	/// A detached shell waits for this process to exit, opens the new bundle and rolls back if it does not stay running.
	private func relaunch() {
		let script = """
			while kill -0 "$PID" 2>/dev/null; do sleep 0.2; done
			open "$APP"
			sleep 30
			if [ -f "$MARKER" ] && ! pgrep -qf "$APP/Contents/MacOS/MinorDLNA" && [ -d "$PREV" ]; then
				rm -rf "$APP.failed"; mv "$APP" "$APP.failed" && mv "$PREV" "$APP" && rm -f "$MARKER" && open "$APP"
			fi
			"""
		let p = Process()
		p.executableURL = URL(filePath: "/bin/sh")
		p.arguments = ["-c", script]
		p.environment = ["PID": String(ProcessInfo.processInfo.processIdentifier), "APP": app.path,
		                 "PREV": Updater.previous(of: app).path, "MARKER": Self.marker.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
		do {
			try p.run()
			NSApp.terminate(nil)
		} catch {
			phase = .failed("Novou verzi nešlo spustit, spusťte MinorDLNA znovu ručně.")
		}
	}
}
