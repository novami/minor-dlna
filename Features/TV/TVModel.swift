import Foundation
import Observation

/// TVs on the network and the one playing, for the library window and the menu.
@MainActor @Observable
final class TVModel {
	private(set) var devices: [Renderer] = []
	private(set) var status: TVStatus?
	private(set) var searching = false
	/// Bumped when playback ends, so lists reload the saved positions.
	private(set) var revision = 0
	var error: String?
	var selectedUDN: String {
		didSet { UserDefaults.standard.set(selectedUDN, forKey: "tv") }
	}

	@ObservationIgnored private let server: MediaServer

	init(server: MediaServer) {
		self.server = server
		selectedUDN = UserDefaults.standard.string(forKey: "tv") ?? ""
		Task { [weak self] in
			var tick = 0
			while let self {
				let st = await server.tvStatus()
				if let old = self.status, old.state != .stopped, st == nil || st?.state == .stopped || st?.itemID != old.itemID {
					self.revision += 1
				}
				if st != self.status { self.status = st }
				if tick % 5 == 0 { self.setDevices(await server.tvDevices()) }
				tick += 1
				try? await Task.sleep(for: .seconds(1))
			}
		}
	}

	/// The chosen TV, else the first one that answered.
	var selected: Renderer? { devices.first { $0.udn == selectedUDN } ?? devices.first { $0.online } }

	private func setDevices(_ d: [Renderer]) {
		if d != devices { devices = d }
	}

	func search() async {
		searching = true
		defer { searching = false }
		do {
			setDevices(try await server.tvSearch())
			error = devices.contains(where: \.online) ? nil : "Žádná televize se neozvala. Zapněte ji a povolte na ní sdílení obsahu (DLNA)."
		} catch {
			self.error = "\(error)"
		}
	}

	func play(_ e: BrowseEntry, fromStart: Bool = false) async {
		guard let tv = selected else {
			error = "Vyberte televizi."
			return
		}
		do {
			try await server.tvPlay(udn: tv.udn, itemID: e.id, fromMs: fromStart || e.watched ? 0 : e.positionMs)
			error = nil
			status = await server.tvStatus()
		} catch {
			self.error = "\(error)"
		}
	}

	func command(_ c: TVCommand) async {
		do {
			try await server.tvCommand(c)
			status = await server.tvStatus()
		} catch {
			self.error = "\(error)"
		}
	}

	func wake(_ tv: Renderer) async {
		do {
			try await server.tvWake(tv.udn)
			error = nil
		} catch {
			self.error = "\(error)"
		}
	}
}
