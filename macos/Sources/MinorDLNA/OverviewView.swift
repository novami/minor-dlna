import MinorCore
import SwiftUI

struct OverviewView: View {
	@Environment(AppModel.self) private var model
	@Environment(\.openSettings) private var openSettings

	var body: some View {
		Form {
			Section {
				LabeledContent("Název na televizi", value: model.settings.name)
				LabeledContent("Stav") { Text(model.statusText).textSelection(.enabled) }
			}
			if let st = model.status, !st.ffmpeg || !st.ffprobe {
				Section {
					Label {
						Text("Chybí \(st.ffmpeg ? "ffprobe" : "ffmpeg"). Bez něj se nepřevádí formáty, které televize neumí, a chybí délky, náhledy a tagy hudby. Nainstalujte ho příkazem `brew install ffmpeg`.")
					} icon: {
						Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
					}
				}
			}
			LibrariesSection(status: model.status) { NSApp.activate(); openSettings() }
			TranscodesSection(sessions: model.status?.transcodes ?? [])
			Section("Zařízení") {
				let clients = (model.status?.clients ?? []).filter { $0.lastSeen != .distantPast }
				if clients.isEmpty {
					Text("Zatím se nepřipojila žádná televize ani přehrávač.").foregroundStyle(.secondary)
				}
				ForEach(clients) { c in
					LabeledContent {
						Text(c.lastSeen, format: .relative(presentation: .named))
					} label: {
						Text(c.ip)
						Text(ProfileOption.label(c.chosen ?? c.detected))
					}
				}
			}
		}
		.formStyle(.grouped)
		.navigationTitle("Přehled")
		.task { await model.watchStatus() }
	}
}

private struct LibrariesSection: View {
	@Environment(AppModel.self) private var model
	let status: ServerStatus?
	let openSettings: () -> Void

	var body: some View {
		Section {
			if model.settings.libraries.isEmpty {
				HStack {
					Text("Zatím žádná knihovna.").foregroundStyle(.secondary)
					Spacer()
					Button("Přidat v Nastavení…", action: openSettings)
				}
			}
			ForEach(model.settings.libraries) { lib in
				let ls = status?.libraries.first { $0.id == lib.id }
				LabeledContent {
					if let ls { Text(czech(ls.items, "položka", "položky", "položek")) } else { Text("–") }
				} label: {
					Text(lib.name)
					Text(lib.type.label)
					if let ls, ls.probing > 0 { Text("Zjišťují se délky a kodeky: zbývá \(ls.probing)") }
					ForEach(ls?.missingPaths ?? [], id: \.self) { path in
						Text("Nedostupná složka: \(path)").foregroundStyle(.orange)
					}
				}
			}
		} header: {
			HStack {
				Text("Knihovny")
				if status?.scanning == true {
					ProgressView().controlSize(.small)
					Text("Prochází se…").foregroundStyle(.secondary)
				}
			}
		}
	}
}

private struct TranscodesSection: View {
	let sessions: [TranscodeSession]

	var body: some View {
		Section("Převody") {
			if sessions.isEmpty {
				Text("Nic se nepřevádí.").foregroundStyle(.secondary)
			}
			ForEach(sessions) { s in
				LabeledContent {
					Text(timerInterval: s.began...Date.distantFuture, countsDown: false).monospacedDigit()
				} label: {
					Text(s.title)
					Text("\(s.client) · \(s.plan)")
				}
			}
		}
	}
}

/// "1 položka", "3 položky", "5 položek".
func czech(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
	"\(n.formatted()) \(n == 1 ? one : (2...4).contains(n) ? few : many)"
}
