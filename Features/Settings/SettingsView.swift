import MinorUpdater
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
				Tab("Metadata", systemImage: "film") { MetadataTab() }
				Tab("Převod", systemImage: "arrow.triangle.2.circlepath") { TranscodeTab() }
				Tab("Zařízení", systemImage: "tv") { DevicesTab() }
				Tab("Úložiště", systemImage: "internaldrive") { StorageTab() }
			}
		}
		.frame(width: 620, height: 480)
		.task { await model.watchStatus() }
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
			Section("Přehrávání na TV") {
				Toggle("Po dohrání dílu spustit další", isOn: $model.settings.autoNextEpisode)
			}
			WebSection()
			Section("Aplikace") {
				Toggle("Spouštět při přihlášení", isOn: $model.launchAtLogin)
			}
			Section {
				Toggle("Automaticky kontrolovat aktualizace", isOn: Bindable(model.updater).automaticChecks)
					.disabled(!model.updater.isAvailable)
				LabeledContent("Aktuální verze", value: AppModel.version)
				UpdateRow(updater: model.updater)
			} header: {
				Text("Aktualizace")
			} footer: {
				Text("Instalují se jen verze podepsané stejným vývojářem z GitHub Releases, s ověřeným kontrolním součtem.")
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

private struct TranscodeTab: View {
	@Environment(AppModel.self) private var model

	var body: some View {
		@Bindable var model = model
		Form {
			if model.status?.ffmpeg == false {
				Text("ffmpeg nenalezen, převod nefunguje. Nainstalujte ho příkazem `brew install ffmpeg`.").foregroundStyle(.orange)
			}
			Section {
				LabeledContent("Nejvýš souběžných převodů") {
					HStack(spacing: 8) {
						Text(String(model.settings.transcode.maxSessions))
							.monospacedDigit()
							.frame(minWidth: 32)
							.padding(.vertical, 3)
							.background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
						Stepper("", value: $model.settings.transcode.maxSessions, in: TranscodeSettings.sessionRange)
							.labelsHidden()
					}
				}
			} footer: {
				Text("Převádí se jen to, co televize sama nepřehraje: video do MPEG-TS s obrazem H.264 a zvukem AAC nebo AC-3, hudba do FLAC. Změna restartuje server.")
			}
			Section {
				Toggle("Televize přehrává zvuk DTS", isOn: $model.settings.transcode.dts)
			} footer: {
				Text("Některé modely LG (2020–2022) DTS neumí. Když film s DTS hraje bez zvuku, vypněte to a zvuk se převede.")
			}
		}
		.formStyle(.grouped)
	}
}

private struct DevicesTab: View {
	@Environment(AppModel.self) private var model

	var body: some View {
		Form {
			Section {
				let clients = model.status?.clients ?? []
				if clients.isEmpty {
					Text("Zatím se nepřipojila žádná televize ani přehrávač. Otevřete MinorDLNA na televizi.").foregroundStyle(.secondary)
				}
				ForEach(clients) { c in
					Picker(selection: Binding(get: { c.chosen ?? "" }, set: { model.choose(profile: $0.isEmpty ? nil : $0, for: c.ip) })) {
						Text("Automaticky (\(ProfileOption.label(c.detected)))").tag("")
						ForEach(ProfileOption.all) { Text($0.label).tag($0.id) }
					} label: {
						Text(c.ip)
						Text(c.ident.isEmpty ? "Dosud se nepřipojilo" : c.ident).lineLimit(1).truncationMode(.tail).help(c.ident)
					}
				}
			} footer: {
				Text("Profil určuje, co zařízení přehraje samo a co se mu převede. Změna platí hned.")
			}
		}
		.formStyle(.grouped)
	}
}

private struct StorageTab: View {
	@Environment(AppModel.self) private var model
	@State private var clearing = false

	var body: some View {
		Form {
			Section {
				LabeledContent("Náhledy, plakáty a fotky pro televizi") {
					if let size = model.cacheSize {
						Text(size, format: .byteCount(style: .file))
					} else {
						ProgressView().controlSize(.small)
					}
				}
				HStack {
					Spacer()
					Button("Smazat mezipaměť") {
						clearing = true
						Task {
							await model.clearCache()
							clearing = false
						}
					}
					.disabled(clearing || model.cacheSize == 0)
				}
			} footer: {
				Text("Náhledy se při dalším procházení na televizi vytvoří znovu, plakáty se hned znovu stáhnou z Wikipedie.")
			}
			Section("Umístění") {
				LabeledContent("Nastavení a index", value: AppPaths.support.path)
				LabeledContent("Mezipaměť", value: CacheStorage.dir.path)
			}
		}
		.formStyle(.grouped)
		.task { await model.refreshCacheSize() }
	}
}

private struct WebSection: View {
	@Environment(AppModel.self) private var model
	@State private var password = ""
	@State private var saving = false
	@State private var saved = false

	var body: some View {
		@Bindable var model = model
		Section {
			Toggle("Povolit přístup z jiných zařízení", isOn: $model.settings.remote.enabled)
			HStack {
				SecureField(model.settings.remote.passwordHash.isEmpty ? "PIN nebo heslo (aspoň \(WebPassword.minLength) znaků)" : "Nový PIN nebo heslo",
				            text: $password)
					.onChange(of: password) { saved = false }
				Button(model.settings.remote.passwordHash.isEmpty ? "Nastavit PIN" : "Změnit PIN") {
					saving = true
					Task {
						await model.setPassword(password)
						password = ""
						saving = false
						saved = true
					}
				}
				.disabled(saving || password.count < WebPassword.minLength)
			}
			if saved { Text("PIN uložen do Klíčenky, přihlášená zařízení byla odhlášena.").foregroundStyle(.secondary) }
			if model.settings.remote.enabled, model.settings.remote.passwordHash.isEmpty {
				Text("Bez PINu nebo hesla zůstane přístup vypnutý.").foregroundStyle(.orange)
			}
			if model.settings.remote.active {
				ForEach(model.remoteURLs, id: \.self) { url in
					LabeledContent("Adresa") { Text(url).textSelection(.enabled) }
				}
			}
		} header: {
			Text("Webové rozhraní")
		} footer: {
			Text("Na tomto Macu se otevře bez hesla přes menu v liště. Jiná zařízení v místní síti se přihlásí PINem nebo heslem, které je uložené v Klíčence. Výchozí stav je vypnuto.")
		}
	}
}

struct UpdateRow: View {
	let updater: Updater

	var body: some View {
		HStack {
			switch updater.state {
			case let .unavailable(reason): Text(reason).foregroundStyle(.secondary)
			case .idle: Text("Dosud nezkontrolováno").foregroundStyle(.secondary)
			case .checking: ProgressView().controlSize(.small); Text("Hledá se aktualizace…")
			case .upToDate: Text("Máte nejnovější verzi.").foregroundStyle(.secondary)
			case let .available(version, _): Text("Dostupná verze: \(version)")
			case .downloading: ProgressView().controlSize(.small); Text("Stahuje se…")
			case let .failed(message): Text(message).foregroundStyle(.orange)
			}
			Spacer()
			if case .available = updater.state {
				Button("Nainstalovat a restartovat") { Task { await updater.installUpdate() } }
			} else {
				Button("Zkontrolovat") { Task { await updater.checkForUpdates() } }
					.disabled(!updater.isAvailable || updater.state == .checking)
			}
		}
	}
}
