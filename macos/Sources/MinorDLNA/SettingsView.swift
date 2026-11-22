import MinorCore
import SwiftUI

struct SettingsView: View {
	@Environment(AppModel.self) private var model

	var body: some View {
		VStack(spacing: 0) {
			if let error = model.error {
				HStack {
					Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
					Text(error).textSelection(.enabled)
					Spacer()
					Button("Zavřít") { model.error = nil }
				}
				.padding(10)
				.background(.orange.opacity(0.12))
			}
			TabView {
				Tab("Obecné", systemImage: "gearshape") { GeneralTab() }
				Tab("Knihovny", systemImage: "books.vertical") { LibrariesTab() }
			}
		}
		.frame(width: 560, height: 440)
	}
}

private struct GeneralTab: View {
	@Environment(AppModel.self) private var model

	var body: some View {
		@Bindable var model = model
		Form {
			Section("Server") {
				TextField("Název na televizi", text: $model.settings.name)
				TextField("Port", value: Binding(
					get: { model.settings.port },
					set: { if Settings.portRange.contains($0) { model.settings.port = $0 } }
				), format: .number.grouping(.never))
			}
			Section("Aplikace") {
				Toggle("Spouštět při přihlášení", isOn: $model.launchAtLogin)
				Toggle("Instalovat aktualizace automaticky", isOn: $model.settings.autoUpdate)
			}
		}
		.formStyle(.grouped)
	}
}

private struct LibrariesTab: View {
	@Environment(AppModel.self) private var model
	@State private var importing = false
	/// Library the picked folders go to; nil creates a new one.
	@State private var target: Library.ID?

	var body: some View {
		@Bindable var model = model
		Form {
			if model.settings.libraries.isEmpty {
				Text("Zatím žádná knihovna. Přidejte složku s filmy, seriály, fotkami nebo hudbou.")
					.foregroundStyle(.secondary)
			}
			ForEach($model.settings.libraries) { $lib in
				Section {
					TextField("Název", text: $lib.name)
					Picker("Typ", selection: $lib.type) {
						ForEach(LibraryType.allCases, id: \.self) { Text($0.label).tag($0) }
					}
					ForEach(lib.paths, id: \.self) { path in
						HStack {
							Image(systemName: "folder")
							Text(path).lineLimit(1).truncationMode(.middle).help(path)
							Spacer()
							Button("Odebrat", systemImage: "minus.circle") { lib.paths.removeAll { $0 == path } }
								.labelStyle(.iconOnly).buttonStyle(.borderless)
						}
					}
					HStack {
						Button("Přidat složku…") { pick(into: lib.id) }
						Spacer()
						Button("Smazat knihovnu", role: .destructive) {
							model.settings.libraries.removeAll { $0.id == lib.id }
						}
					}
				}
			}
			Section {
				Button("Nová knihovna…") { pick(into: nil) }
			}
		}
		.formStyle(.grouped)
		.fileImporter(isPresented: $importing, allowedContentTypes: [.folder], allowsMultipleSelection: true) { result in
			if case .success(let urls) = result { model.addFolders(urls, to: target) }
		}
	}

	private func pick(into id: Library.ID?) {
		target = id
		importing = true
	}
}
