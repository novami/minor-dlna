import MinorCore
import SwiftUI

/// Browses the libraries and plays items on a TV.
struct LibraryView: View {
	@Environment(AppModel.self) private var model
	@State private var path: [String] = []
	@State private var query = ""

	var body: some View {
		let tv = model.tv!
		NavigationStack(path: $path) {
			Group {
				if query.trimmingCharacters(in: .whitespaces).isEmpty {
					ContainerList(id: "0")
				} else {
					SearchResults(query: query)
				}
			}
			.navigationDestination(for: String.self) { ContainerList(id: $0) }
		}
		.searchable(text: $query, placement: .toolbar, prompt: "Hledat filmy, seriály, hudbu")
		.toolbar { ToolbarItem(placement: .primaryAction) { TVPicker() } }
		.safeAreaInset(edge: .bottom, spacing: 0) {
			VStack(spacing: 0) {
				if let err = tv.error {
					HStack {
						Label(err, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
						Spacer()
						Button("Zavřít") { tv.error = nil }.buttonStyle(.link)
					}
					.padding(8)
					.background(.bar)
				}
				if let st = tv.status { RemoteBar(status: st) }
			}
		}
		.frame(minWidth: 560, minHeight: 420)
	}
}

/// The entries of one container; reloads when playback ends, as positions change.
private struct ContainerList: View {
	@Environment(AppModel.self) private var model
	let id: String
	@State private var page: BrowsePage?
	@State private var missing = false

	var body: some View {
		Group {
			if let page {
				if page.entries.isEmpty {
					ContentUnavailableView(id == "0" ? "Žádná knihovna" : "Prázdné", systemImage: "folder",
					                       description: Text(id == "0" ? "Přidejte knihovnu v Nastavení." : ""))
				} else {
					List(page.entries) { EntryRow(entry: $0) }
				}
			} else if missing {
				ContentUnavailableView("Položka už neexistuje", systemImage: "questionmark.folder")
			} else {
				ProgressView()
			}
		}
		.navigationTitle(id == "0" ? "Knihovna" : page?.title ?? "")
		.task(id: "\(id)#\(model.tv.revision)#\(model.serverState)") {
			page = await model.browse(id)
			missing = page == nil
		}
	}
}

private struct SearchResults: View {
	@Environment(AppModel.self) private var model
	let query: String
	@State private var results: [BrowseEntry]?

	var body: some View {
		Group {
			if let results, results.isEmpty {
				ContentUnavailableView.search(text: query)
			} else if let results {
				List(results) { EntryRow(entry: $0) }
			} else {
				ProgressView()
			}
		}
		.navigationTitle("Hledání")
		.task(id: "\(query)#\(model.tv.revision)") {
			try? await Task.sleep(for: .milliseconds(250)) // typing
			guard !Task.isCancelled else { return }
			results = await model.search(query)
		}
	}
}

private struct EntryRow: View {
	@Environment(AppModel.self) private var model
	let entry: BrowseEntry

	var body: some View {
		let tv = model.tv!
		let row = HStack(spacing: 10) {
			Art(url: model.artURL(entry.artPath), kind: entry.kind)
			VStack(alignment: .leading, spacing: 2) {
				Text(entry.title).lineLimit(1)
				HStack(spacing: 6) {
					if let d = entry.durationMs { Text(Self.time(d)) }
					if entry.watched {
						Label("Zhlédnuto", systemImage: "checkmark.circle.fill").labelStyle(.titleAndIcon)
					} else if entry.positionMs > 0, let d = entry.durationMs, d > 0 {
						ProgressView(value: Double(min(entry.positionMs, d)), total: Double(d)).frame(width: 60)
						Text("zbývá \(Self.time(d - entry.positionMs))")
					}
					if let n = entry.childCount, entry.kind == .folder { Text("\(n) položek") }
				}
				.font(.caption)
				.foregroundStyle(.secondary)
			}
			Spacer()
			if entry.playable {
				let resume = entry.positionMs > 0 && !entry.watched
				Button(resume ? "Pokračovat" : "Přehrát", systemImage: "play.fill") { Task { await tv.play(entry) } }
					.disabled(tv.selected == nil)
					.help(tv.selected.map { "Přehrát na \($0.name)" } ?? "Nejdřív vyberte televizi")
			}
		}
		.contextMenu {
			if entry.playable {
				Button("Přehrát od začátku") { Task { await tv.play(entry, fromStart: true) } }.disabled(tv.selected == nil)
			}
		}
		if entry.kind == .folder {
			NavigationLink(value: entry.id) { row }
		} else {
			row
		}
	}

	static func time(_ ms: Int) -> String {
		let s = max(ms, 0) / 1000
		return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
	}
}

private struct Art: View {
	let url: URL?
	let kind: BrowseEntry.Kind

	var body: some View {
		AsyncImage(url: url) { img in
			img.resizable().scaledToFit()
		} placeholder: {
			Image(systemName: Self.symbol(kind)).font(.title3).foregroundStyle(.secondary)
		}
		.frame(width: 44, height: 44)
		.clipShape(RoundedRectangle(cornerRadius: 4))
	}

	static func symbol(_ k: BrowseEntry.Kind) -> String {
		switch k {
		case .folder: "folder"
		case .video: "film"
		case .audio: "music.note"
		case .image: "photo"
		}
	}
}

private struct TVPicker: View {
	@Environment(AppModel.self) private var model

	var body: some View {
		let tv = model.tv!
		Menu {
			ForEach(tv.devices) { d in
				Button {
					tv.selectedUDN = d.udn
				} label: {
					if d.udn == tv.selected?.udn { Image(systemName: "checkmark") }
					Text(d.online ? d.name : "\(d.name) (nenalezena)")
				}
			}
			if !tv.devices.isEmpty { Divider() }
			Button(tv.searching ? "Hledám…" : "Hledat televize") { Task { await tv.search() } }.disabled(tv.searching)
			if let d = tv.selected, !d.online, !d.mac.isEmpty {
				Button("Zapnout \(d.name)") { Task { await tv.wake(d) } }
			}
		} label: {
			Label(tv.selected?.name ?? "Televize", systemImage: "tv")
		}
		.help("Televize, na které se přehrává")
	}
}

/// Remote control of the playing TV.
private struct RemoteBar: View {
	@Environment(AppModel.self) private var model
	let status: TVStatus
	@State private var seeking: Double?
	@State private var volume: Double?
	/// Volume commands run one after another, so the TV ends at the last value.
	@State private var volumeTask: Task<Void, Never>?

	var body: some View {
		let tv = model.tv!
		let playing = status.state == .playing
		VStack(alignment: .leading, spacing: 6) {
			HStack {
				VStack(alignment: .leading) {
					Text(status.title).font(.headline).lineLimit(1)
					Text("\(status.tv) · \(Self.stateText(status))").font(.caption).foregroundStyle(status.error == nil ? .secondary : Color.orange)
				}
				Spacer()
				if status.state != .stopped {
					Button(playing ? "Pauza" : "Přehrát", systemImage: playing ? "pause.fill" : "play.fill") {
						Task { await tv.command(playing ? .pause : .play) }
					}
					.labelStyle(.iconOnly)
					.keyboardShortcut(.space, modifiers: [])
					Button("Zastavit", systemImage: "stop.fill") { Task { await tv.command(.stop) } }.labelStyle(.iconOnly)
				}
				if status.canVolume, status.state != .stopped {
					Button(status.muted ? "Zapnout zvuk" : "Ztlumit", systemImage: status.muted ? "speaker.slash.fill" : "speaker.wave.2.fill") {
						Task { await tv.command(.mute(!status.muted)) }
					}
					.labelStyle(.iconOnly)
					Slider(value: Binding(get: { volume ?? Double(status.volume) }, set: { setVolume($0) }), in: 0...100, step: 10) {
						Text("Hlasitost")
					} minimumValueLabel: {
						EmptyView()
					} maximumValueLabel: {
						EmptyView()
					} onEditingChanged: { editing in
						// Keep showing the dragged value until the last command is through.
						if !editing { let last = volumeTask; Task { await last?.value; volume = nil } }
					}
					.labelsHidden()
					.frame(width: 150)
				}
			}
			if status.durationMs > 0, status.state != .stopped {
				HStack {
					Text(EntryRow.time(Int(seeking ?? Double(status.positionMs)))).monospacedDigit()
					Slider(value: Binding(get: { seeking ?? Double(min(status.positionMs, status.durationMs)) }, set: { seeking = $0 }),
					       in: 0...Double(status.durationMs)) { editing in
						if !editing, let to = seeking { Task { await tv.command(.seek(ms: Int(to))); seeking = nil } }
					}
					Text(EntryRow.time(status.durationMs)).monospacedDigit()
				}
				.font(.caption)
			}
		}
		.padding(10)
		.background(.bar)
	}

	private func setVolume(_ v: Double) {
		guard v != (volume ?? Double(status.volume)) else { return }
		volume = v
		let previous = volumeTask, tv = model.tv!
		volumeTask = Task {
			await previous?.value
			// A newer step is already waiting: skip this one.
			guard volume == nil || volume == v else { return }
			await tv.command(.volume(Int(v)))
		}
	}

	static func stateText(_ s: TVStatus) -> String {
		if let e = s.error { return e }
		return switch s.state {
		case .starting: "Spouštím…"
		case .waking: "Zapínám televizi…"
		case .playing: "Přehrává"
		case .paused: "Pozastaveno"
		case .transitioning: "Načítá…"
		case .stopped, .noMedia: "Zastaveno"
		}
	}
}
