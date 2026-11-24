import AppKit
import SwiftUI

struct MetadataTab: View {
	@Environment(AppModel.self) private var model
	@State private var filter = ""
	@State private var editing: MetaEntry?

	var body: some View {
		@Bindable var model = model
		VStack(alignment: .leading, spacing: 8) {
			Toggle("Stahovat české názvy, popisy a plakáty filmů a seriálů z Wikidat a Wikipedie", isOn: $model.settings.metadata)
			if model.settings.metadata {
				TextField("Hledat v názvech", text: $filter).textFieldStyle(.roundedBorder)
				List(shown) { e in
					MetaRow(entry: e).contentShape(Rectangle())
						.contextMenu { Button("Upravit…") { editing = e } }
						.onTapGesture(count: 2) { editing = e }
				}
				.overlay {
					if model.metaEntries.isEmpty { Text("Zatím žádné filmy ani seriály.").foregroundStyle(.secondary) }
				}
				Text("Dvojklikem na název vyberete správný film nebo seriál ručně.").font(.caption).foregroundStyle(.secondary)
			}
		}
		.padding()
		.task(id: model.settings.metadata) {
			while !Task.isCancelled {
				await model.refreshMetadata()
				try? await Task.sleep(for: .seconds(5))
			}
		}
		.sheet(item: $editing) { MetaEditor(entry: $0) }
	}

	private var shown: [MetaEntry] {
		let f = filter.trimmingCharacters(in: .whitespaces)
		guard !f.isEmpty else { return model.metaEntries }
		return model.metaEntries.filter { e in
			[e.fileTitle, e.title ?? ""].contains { $0.localizedStandardContains(f) }
		}
	}
}

private struct MetaRow: View {
	let entry: MetaEntry

	var body: some View {
		HStack(spacing: 10) {
			Poster(url: entry.poster).frame(width: 32, height: 48)
			VStack(alignment: .leading) {
				Text(entry.title.map { t in entry.year.map { "\(t) (\($0))" } ?? t } ?? fileName)
				Text(detail).font(.caption).foregroundStyle(.secondary)
			}
			Spacer()
			if entry.isShow { Text("Seriál").font(.caption).foregroundStyle(.secondary) }
		}
	}

	private var fileName: String { entry.fileYear.map { "\(entry.fileTitle) (\($0))" } ?? entry.fileTitle }

	private var detail: String {
		switch entry.status {
		case .pending: entry.checked ? "Nenalezeno: \(fileName)" : "Hledá se…"
		case .auto: "Soubor: \(fileName)"
		case .manual: "Vybráno ručně · soubor: \(fileName)"
		case .none: "Bez metadat · soubor: \(fileName)"
		}
	}
}

private struct Poster: View {
	let url: URL?

	var body: some View {
		if let url, let img = NSImage(contentsOf: url) {
			Image(nsImage: img).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 3))
		} else {
			RoundedRectangle(cornerRadius: 3).fill(.quaternary)
		}
	}
}

private struct MetaEditor: View {
	@Environment(AppModel.self) private var model
	@Environment(\.dismiss) private var dismiss
	let entry: MetaEntry
	@State private var query = ""
	@State private var results: [MetaCandidate]?
	@State private var busy = false
	@State private var error: String?

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			Text(entry.fileYear.map { "\(entry.fileTitle) (\($0))" } ?? entry.fileTitle).font(.headline)
			HStack {
				TextField("Název filmu nebo seriálu", text: $query).textFieldStyle(.roundedBorder).onSubmit(search)
				Button("Hledat", action: search).disabled(busy || query.trimmingCharacters(in: .whitespaces).isEmpty)
			}
			List(results ?? []) { c in
				Button { run { try await model.setMetadata(entry.id, wikidata: c.id) } } label: {
					VStack(alignment: .leading) {
						Text(c.year.map { "\(c.title) (\($0))" } ?? c.title)
						if !c.description.isEmpty { Text(c.description).font(.caption).foregroundStyle(.secondary) }
					}
					.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
				}
				.buttonStyle(.plain)
				.disabled(busy)
			}
			.overlay {
				if busy { ProgressView() } else if results?.isEmpty == true { Text("Nic nenalezeno.").foregroundStyle(.secondary) }
			}
			if let error { Text(error).foregroundStyle(.orange) }
			HStack {
				Button("Bez metadat") { run { try await model.setMetadata(entry.id, wikidata: nil) } }
				Button("Najít znovu automaticky") {
					Task {
						await model.rematchMetadata(entry.id)
						dismiss()
					}
				}
				Spacer()
				Button("Zrušit", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
			}
			.disabled(busy)
		}
		.padding()
		.frame(width: 480, height: 420)
		.onAppear {
			query = entry.fileTitle
			search()
		}
	}

	private func search() {
		let q = query.trimmingCharacters(in: .whitespaces)
		guard !q.isEmpty else { return }
		busy = true
		error = nil
		Task {
			do { results = try await model.searchMetadata(entry.id, q) } catch { self.error = "Hledání selhalo: \(error.localizedDescription)" }
			busy = false
		}
	}

	/// Saving a match downloads details and the poster, which takes a few seconds.
	private func run(_ body: @escaping () async throws -> Void) {
		busy = true
		error = nil
		Task {
			do {
				try await body()
				dismiss()
			} catch {
				self.error = "Uložení selhalo: \(error.localizedDescription)"
			}
			busy = false
		}
	}
}
