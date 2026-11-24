import Foundation
import ImageIO
import Network
import UniformTypeIdentifiers

nonisolated struct ServerConfig: Sendable, Equatable {
	var name: String
	var uuid: UUID
	var port: Int
	var libraries: [Library]
	var version: String
	/// Image the device icons are rendered from (the app's .icns).
	var iconURL: URL?
	var databaseURL: URL
	var transcode: TranscodeSettings
	var remote: RemoteSettings
	var metadata: Bool
	var autoNextEpisode: Bool

	init(settings: Settings, version: String, iconURL: URL?, databaseURL: URL = Store.defaultURL) {
		name = settings.name.trimmingCharacters(in: .whitespaces).isEmpty ? "MinorDLNA" : settings.name
		uuid = settings.uuid
		port = settings.port
		libraries = settings.libraries
		self.version = version
		self.iconURL = iconURL
		self.databaseURL = databaseURL
		transcode = settings.transcode
		remote = settings.remote
		metadata = settings.metadata
		autoNextEpisode = settings.autoNextEpisode
	}
}

nonisolated enum ServerState: Sendable, Equatable {
	case stopped
	case starting
	case running(port: Int, addresses: [String])
	case failed(String)
}

/// Runs the HTTP server and SSDP for one configuration; start() again to apply a new one.
actor MediaServer {
	/// State changes in order; consume from one task.
	nonisolated let states: AsyncStream<ServerState>
	private let continuation: AsyncStream<ServerState>.Continuation
	private var task: Task<Void, Never>?
	/// Kept open across restarts.
	private var store: (url: URL, store: Store)?
	private var running: (routes: Routes, scanner: LibraryScanner, libraries: [IndexedLibrary])?
	/// Outlives restarts, so web users stay logged in.
	private let web = WebAccess()

	init() { (states, continuation) = AsyncStream.makeStream() }

	private nonisolated func onState(_ s: ServerState) { continuation.yield(s) }

	func start(_ config: ServerConfig) async {
		await stop()
		onState(.starting)
		let ssdp = SSDPService(uuid: config.uuid.uuidString.lowercased(), port: config.port, serverHeader: Self.serverHeader(config.version),
		                       services: [Descriptions.cdsType, Descriptions.cmsType])
		let store: Store, libraries: [IndexedLibrary]
		do {
			store = try openStore(config.databaseURL)
			let ids = try store.syncLibraries(config.libraries)
			libraries = config.libraries.compactMap { l in ids[l.id].map { IndexedLibrary(id: $0, library: l) } }
		} catch {
			AppLog.server.error("index unavailable: \(error, privacy: .public)")
			onState(.failed("Index knihovny nejde otevřít: \(error)"))
			return
		}
		web.configure(config.remote)
		var r = Routes(config: config, store: store, libraries: libraries, web: web)
		let cds = r.cds
		let meta = config.metadata ? MetadataService(store: store) {
			_ = try? store.bumpUpdateID()
			Task { await cds.notifyAll() }
		} : nil
		r.meta = meta
		let routes = r
		let scanner = LibraryScanner(store: store, libraries: libraries) { _ in
			meta?.kick()
			Task { await routes.cds.notifyAll() }
		}
		let onState = { @Sendable (s: ServerState) in self.onState(s) }
		let router = routes.router()
		let http = HTTPServer(port: config.port, serverName: Self.serverHeader(config.version)) { await router.handle($0) }
		let services: [any BackgroundService] = [ssdp, scanner, routes.tv] + (meta.map { [$0] } ?? [])
		running = (routes, scanner, libraries)
		task = Task {
			await withTaskGroup(of: Bool.self) { group in
				group.addTask {
					do {
						try await http.run {
							onState(.running(port: config.port, addresses: LANInterface.all().map(\.ip)))
							AppLog.server.info("listening on port \(config.port)")
						}
					} catch {
						if !Task.isCancelled {
							AppLog.server.error("server failed: \(error, privacy: .public)")
							onState(.failed(Self.describe(error, port: config.port)))
							return true
						}
					}
					return false
				}
				for service in services {
					group.addTask {
						await service.run()
						return false
					}
				}
				var failed = false
				for await f in group where f && !failed {
					failed = true
					group.cancelAll()
				}
				if !failed { onState(.stopped) }
			}
		}
	}

	private func openStore(_ url: URL) throws -> Store {
		if let store, store.url == url { return store.store }
		let s = try Store(url: url)
		store = (url, s)
		return s
	}

	func stop() async {
		guard let task else { return }
		task.cancel()
		await task.value
		self.task = nil
		running = nil
	}

	/// nil while the server is not running.
	func status() -> ServerStatus? {
		guard let (routes, scanner, libraries) = running else { return nil }
		let counts = routes.store.counts(), missing = scanner.missingRoots()
		return ServerStatus(
			libraries: libraries.map { l in
				LibraryStatus(id: l.library.id, items: counts[l.id]?.items ?? 0, probing: counts[l.id]?.probing ?? 0, missingPaths: missing[l.id] ?? [])
			},
			scanning: scanner.scanning, transcodes: routes.transcoder.current, clients: routes.profiles.list(),
			ffmpeg: routes.transcoder.available, ffprobe: scanner.prober.available)
	}

	/// Applies web access settings without a restart; a new password logs everybody out.
	func setRemote(_ remote: RemoteSettings) { web.configure(remote) }

	// MARK: Metadata by hand; nil or empty while the server or metadata is off.

	func metadataEntries() -> [MetaEntry] { (try? running?.routes.meta?.entries()) ?? [] }

	func metadataSearch(_ id: Int64, _ query: String) async throws -> [MetaCandidate] {
		guard let meta = running?.routes.meta else { return [] }
		return try await meta.search(id, query)
	}

	/// nil wikidata: no metadata for the title.
	func metadataSet(_ id: Int64, wikidata: String?) async throws {
		try await running?.routes.meta?.set(id, wikidata: wikidata)
	}

	func metadataRematch(_ id: Int64) throws { try running?.routes.meta?.rematch(id) }

	/// Deletes thumbnails and posters; posters are downloaded again right away.
	func clearCache() throws {
		try CacheStorage.clear()
		guard let meta = running?.routes.meta else { return }
		try meta.refetchMissingPosters()
		meta.kick()
	}

	/// Applies hand-picked client profiles without a restart.
	// MARK: Library

	/// A container's entries; nil when it does not exist (anymore).
	func browse(_ id: String) -> BrowsePage? { try? running?.routes.catalog.page(id) }

	func search(_ query: String) -> [BrowseEntry] { running?.routes.catalog.search(query).map(BrowseEntry.init) ?? [] }

	// MARK: Play on TV

	private var tv: TVController {
		get throws {
			guard let tv = running?.routes.tv else { throw TVError("Server neběží.") }
			return tv
		}
	}

	func tvDevices() async -> [Renderer] { await running?.routes.tv.devices() ?? [] }
	func tvSearch() async throws -> [Renderer] { try await tv.search() }
	func tvWake(_ udn: String) async throws { try await tv.wake(udn) }
	/// Applies to the running session too.
	func setAutoNextEpisode(_ on: Bool) async { await running?.routes.tv.setAutoNext(on) }
	func tvStatus() async -> TVStatus? { await running?.routes.tv.status() }
	func tvCommand(_ c: TVCommand) async throws { try await tv.command(c) }

	/// fromMs > 0 resumes there.
	func tvPlay(udn: String, itemID: String, fromMs: Int = 0) async throws {
		try await tv.play(udn: udn, id: itemID, fromMs: fromMs)
	}

	func chooseProfiles(_ clients: [String: String]) {
		running?.routes.profiles.choose(clients)
	}

	static func serverHeader(_ version: String) -> String {
		let v = ProcessInfo.processInfo.operatingSystemVersion
		return "macOS/\(v.majorVersion).\(v.minorVersion) UPnP/1.0 DLNADOC/1.50 MinorDLNA/\(version)"
	}

	private static func describe(_ error: any Error, port: Int) -> String {
		if case let .posix(code)? = error as? NWError {
			if code == .EADDRINUSE { return "Port \(port) už používá jiná aplikace." }
			if code == .EACCES { return "Port \(port) není povolený." }
		}
		return "Server se nepodařilo spustit: \(error)"
	}
}

nonisolated struct Routes: Sendable {
	let config: ServerConfig
	let catalog: LibraryCatalog
	let store: Store
	let cds: Eventer
	let cms: Eventer
	let icons: [Int: Data]
	let thumbnails = Thumbnails()
	let transcoder: Transcoder
	let profiles: ClientProfiles
	let web: WebRoutes
	/// Set before the server starts; nil when metadata is off.
	var meta: MetadataService?
	let tv: TVController

	init(config: ServerConfig, store: Store, libraries: [IndexedLibrary], web access: WebAccess = WebAccess()) {
		self.config = config
		self.store = store
		transcoder = Transcoder(hardware: true, maxSessions: config.transcode.maxSessions)
		profiles = ClientProfiles(dts: config.transcode.dts, chosen: config.transcode.clients)
		catalog = LibraryCatalog(db: store.reader, libraries: libraries, videoArt: thumbnails.ffmpeg != nil)
		let cds = Eventer { [("SystemUpdateID", String(store.updateID())), ("ContainerUpdateIDs", "")] }
		self.cds = cds
		tv = TVController(store: store, catalog: catalog, port: config.port, profiles: profiles, transcode: transcoder.available,
		                  autoNext: config.autoNextEpisode) {
			_ = try? store.bumpUpdateID()
			Task { await cds.notifyAll() }
		}
		cms = Eventer { [("SourceProtocolInfo", MediaFormat.sourceProtocolInfo), ("SinkProtocolInfo", ""), ("CurrentConnectionIDs", "0")] }
		icons = config.iconURL.map(Self.renderIcons) ?? [:]
		let positionSaved = { @Sendable in
			_ = try? store.bumpUpdateID()
			Task { await cds.notifyAll() }
		}
		let state = { @Sendable [config, store] in
			let counts = store.counts()
			return WebRoutes.WebState(name: config.name, version: config.version, libraries: libraries.map {
				.init(name: $0.library.name, type: $0.type.rawValue, items: counts[$0.id]?.items ?? 0)
			})
		}
		web = WebRoutes(access: access, catalog: catalog, tv: tv, store: store, transcoder: transcoder,
		                hls: HLSSessions(transcoder: transcoder), positionSaved: positionSaved, state: state)
	}

	func router() -> Router {
		let r = Router()
		r.get("/description.xml") { _ in
			xml(Descriptions.device(name: config.name, version: config.version, uuid: config.uuid.uuidString.lowercased()))
		}
		r.get("/cds.xml") { _ in xml(Descriptions.cds) }
		r.get("/cms.xml") { _ in xml(Descriptions.cms) }
		r.post("/cds/control") { req in control(req, serviceType: Descriptions.cdsType, handler: cdsAction) }
		r.post("/cms/control") { req in control(req, serviceType: Descriptions.cmsType, handler: cmsAction) }
		for (path, ev) in [("/cds/event", cds), ("/cms/event", cms)] {
			r.on(.subscribe, path) { req in await subscribe(req, ev) }
			r.on(.unsubscribe, path) { req in HTTPResponse(status: await ev.unsubscribe(sid: req.headers[.sid]) ? .ok : .preconditionFailed) }
		}
		r.get("/icon/:size") { req in
			guard let size = Int((req.parameters["size"] ?? "").replacingOccurrences(of: ".png", with: "")), let png = icons[size] else {
				return HTTPResponse(status: .notFound)
			}
			return HTTPResponse(status: .ok, headers: [.contentType: "image/png"], body: .data(png))
		}
		for method in [HTTPMethod.get, .head] {
			r.on(method, "/media/:token") { req in media(req) }
			r.on(method, "/transcode/:item/:file") { req in await transcode(req) }
			r.on(method, "/subs/:file") { req in subtitles(req) }
			r.on(method, "/poster/:meta/:size") { req in poster(req) }
			r.on(method, "/thumb/:item/:size") { req in await thumb(req) }
		}
		web.register(r)
		return r
	}

	// MARK: SOAP

	/// Who is asking: the server address as the client sees it, and what it plays (nil: no transcoding).
	struct Client {
		var baseURL: String
		var profile: Profile?
	}

	private typealias Action = @Sendable (SOAP.Call, Client) throws(UPnPError) -> KeyValuePairs<String, String>

	private func client(_ req: HTTPRequest) -> Client {
		let baseURL = "http://" + (req.authority ?? "localhost:\(config.port)")
		guard transcoder.available else { return Client(baseURL: baseURL) }
		// Older Sony TVs name themselves only in X-AV-Client-Info.
		let ident = (req.headers[.userAgent] ?? "") + " " + (req.headers[.avClientInfo] ?? "")
		return Client(baseURL: baseURL, profile: profiles.profile(ip: req.remoteIP, ident: ident))
	}

	private func control(_ req: HTTPRequest, serviceType: String, handler: Action) -> HTTPResponse {
		guard let call = SOAP.parse(req.body, soapAction: req.headers[.soapAction]) else {
			return fault(.invalidArgs)
		}
		do {
			let out = try handler(call, client(req))
			var r = xml(SOAP.response(action: call.action, serviceType: serviceType, args: out))
			r.headers[.ext] = ""
			return r
		} catch {
			AppLog.server.debug("soap fault \(call.action, privacy: .public): \(error.code)")
			return fault(error)
		}
	}

	private func cdsAction(_ call: SOAP.Call, client: Client) throws(UPnPError) -> KeyValuePairs<String, String> {
		switch call.action {
		case "Browse":
			let id = call.args["ObjectID"] ?? ""
			guard let start = Int(call.args["StartingIndex"].nonEmpty ?? "0"), let count = Int(call.args["RequestedCount"].nonEmpty ?? "0"),
			      start >= 0, count >= 0 else { throw .invalidArgs }
			let objs: [CatalogObject], total: Int
			switch call.args["BrowseFlag"] {
			case "BrowseMetadata": (objs, total) = ([try catalog.metadata(id)], 1)
			case "BrowseDirectChildren": (objs, total) = try catalog.children(id, start: start, count: count)
			default: throw .invalidArgs
			}
			return ["Result": DIDL.render(objs, baseURL: client.baseURL, profile: client.profile), "NumberReturned": String(objs.count),
			        "TotalMatches": String(total), "UpdateID": String(store.updateID())]
		case "GetSearchCapabilities": return ["SearchCaps": ""]
		case "GetSortCapabilities": return ["SortCaps": "dc:title"]
		case "GetSystemUpdateID": return ["Id": String(store.updateID())]
		case "X_GetFeatureList": // Samsung asks where its basic view should start
			return ["FeatureList": Self.featureList]
		case "X_SetBookmark": // Samsung reports where the viewer stopped
			guard let sec = Int(call.args["PosSecond"]?.trimmingCharacters(in: .whitespaces) ?? ""), sec >= 0,
			      let id = call.args["ObjectID"], id.first == "I" else { throw .invalidArgs }
			guard let path = catalog.media(id.dropFirst())?.path else { throw .noSuchObject }
			try? store.savePosition(path: path, positionMs: sec * 1000, durationMs: 0)
			return [:]
		default: throw .invalidAction
		}
	}

	private static let featureList = """
		<?xml version="1.0" encoding="UTF-8"?><Features xmlns="urn:schemas-upnp-org:av:avs" \
		xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:schemaLocation="urn:schemas-upnp-org:av:avs http://www.upnp.org/schemas/av/avs.xsd">\
		<Feature name="samsung.com_BASICVIEW" version="1">\
		<container id="0" type="object.item.audioItem"/><container id="0" type="object.item.videoItem"/><container id="0" type="object.item.imageItem"/>\
		</Feature></Features>
		"""

	private func cmsAction(_ call: SOAP.Call, client _: Client) throws(UPnPError) -> KeyValuePairs<String, String> {
		switch call.action {
		case "GetProtocolInfo": return ["Source": MediaFormat.sourceProtocolInfo, "Sink": ""]
		case "GetCurrentConnectionIDs": return ["ConnectionIDs": "0"]
		case "GetCurrentConnectionInfo":
			guard call.args["ConnectionID"] == "0" else { throw UPnPError(code: 706, description: "Invalid connection reference") }
			return ["RcsID": "-1", "AVTransportID": "-1", "ProtocolInfo": "", "PeerConnectionManager": "",
			        "PeerConnectionID": "-1", "Direction": "Output", "Status": "OK"]
		default: throw .invalidAction
		}
	}

	private func subscribe(_ req: HTTPRequest, _ ev: Eventer) async -> HTTPResponse {
		let outcome = await ev.subscribe(remoteIP: req.remoteIP, sid: req.headers[.sid], nt: req.headers[.nt],
		                                 callback: req.headers[.callback], timeout: req.headers[.timeout])
		guard case let .ok(sid, timeout) = outcome else { return HTTPResponse(status: .preconditionFailed) }
		return HTTPResponse(status: .ok, headers: [.sid: sid, .timeout: "Second-\(timeout)"])
	}

	// MARK: Media

	/// Originals are served with Range, so TVs can seek; the catalog only hands out files inside the libraries.
	private func media(_ req: HTTPRequest) -> HTTPResponse {
		guard let obj = catalog.media(Substring(req.parameters["token"] ?? "")), let path = obj.path, let format = obj.format else {
			return HTTPResponse(status: .notFound)
		}
		var h: HTTPHeaders = [.contentType: format.mime, .acceptRanges: "bytes"]
		let mode = req.headers[.transferMode]
		h[.transferMode] = ["Streaming", "Interactive", "Background"].contains(mode ?? "") ? mode : format.transferMode
		if req.headers[.getContentFeatures] == "1" { h[.contentFeatures] = format.contentFeatures }
		if let m = obj.modified { h[.lastModified] = httpDate.string(from: m) }
		captions(obj, req, &h)

		var status = HTTPStatus.ok
		var range: ClosedRange<Int64> = 0...max(obj.size - 1, 0)
		if let header = req.headers[.range] {
			guard let r = ByteRange.parse(header, size: obj.size) else {
				h[.contentRange] = "bytes */\(obj.size)"
				return HTTPResponse(status: .rangeNotSatisfiable, headers: h)
			}
			range = r
			status = .partialContent
			h[.contentRange] = "bytes \(r.lowerBound)-\(r.upperBound)/\(obj.size)"
		}
		let length = obj.size == 0 ? 0 : range.upperBound - range.lowerBound + 1
		h[.contentLength] = String(length)
		if req.method == .head || length == 0 { return HTTPResponse(status: status, headers: h) }
		AppLog.server.info("stream \(obj.title, privacy: .private) range \(req.headers[.range] ?? "-", privacy: .public)")
		return HTTPResponse(status: status, headers: h, body: .file(path: path, offset: range.lowerBound, length: length))
	}

	/// Announces external subtitles to the TV player.
	private func captions(_ o: CatalogObject, _ req: HTTPRequest, _ h: inout HTTPHeaders) {
		guard o.subtitle != nil, let n = Int64(o.id.dropFirst()) else { return }
		h[.captionInfo] = "http://" + (req.authority ?? "localhost:\(config.port)") + Subtitles.path(item: n)
	}

	private func subtitles(_ req: HTTPRequest) -> HTTPResponse {
		let name = req.parameters["file"] ?? ""
		guard name.hasSuffix(".srt"), let obj = catalog.media(Substring(name.dropLast(4))), let path = obj.subtitle,
		      let fh = FileHandle(forReadingAtPath: path) else { return HTTPResponse(status: .notFound) }
		defer { try? fh.close() }
		let data = Subtitles.utf8((try? fh.read(upToCount: 5 << 20)) ?? Data())
		let h: HTTPHeaders = [.contentType: "text/srt; charset=utf-8", .contentLength: String(data.count)]
		if req.method == .head { return HTTPResponse(status: .ok, headers: h) }
		return HTTPResponse(status: .ok, headers: h, body: .data(data))
	}

	private func transcode(_ req: HTTPRequest) async -> HTTPResponse {
		let file = req.parameters["file"] ?? ""
		guard transcoder.available, let plan = Plan(key: file.prefix { $0 != "." }),
		      let item = req.parameters["item"], Int64(item) != nil, let obj = catalog.media(Substring(item)),
		      let path = obj.path, let kind = obj.format?.kind, kind == .video || kind == .audio,
		      plan.video == nil || kind == .video else { return HTTPResponse(status: .notFound) }

		var h: HTTPHeaders = [.contentType: plan.mime, .transferMode: "Streaming"]
		if req.headers[.getContentFeatures] == "1" { h[.contentFeatures] = Plan.contentFeatures }
		captions(obj, req, &h)
		var start = 0.0
		let dur = Double(obj.durationMs ?? 0) / 1000
		// A live conversion cannot use Range, so the TV seeks by time: ffmpeg restarts at the asked position.
		if let tsr = req.headers[.timeSeekRange] {
			guard let from = Transcoder.parseNPT(tsr), dur <= 0 || from < dur else { return HTTPResponse(status: .rangeNotSatisfiable, headers: h) }
			start = from
			// A copied stream starts at the keyframe before, and the reply says where it really starts.
			if plan.video != nil, plan.video == .copy || plan.audio == .copy { start = await transcoder.keyframe(path, before: start) }
			if dur > 0 { h[.timeSeekRange] = String(format: "npt=%.3f-%.3f/%.3f", start, dur, dur) }
		}
		if req.method == .head { return HTTPResponse(status: .ok, headers: h) }
		guard let lease = await transcoder.acquire() else {
			AppLog.server.warning("transcode refused, all sessions busy")
			return HTTPResponse.text("Všechny převody jsou obsazené, zkuste to za chvíli.", status: .serviceUnavailable)
		}
		let args = Transcoder.args(plan, path: path, start: start, hardware: transcoder.hardware,
		                           decodesInHardware: Transcoder.decodesInHardware(obj))
		let session = TranscodeSession(title: obj.title, client: req.remoteIP, plan: plan.key)
		return HTTPResponse(status: .ok, headers: h, body: .stream { [transcoder, start] writer in
			try await transcoder.stream(args, session: session, from: start, lease: lease, to: writer)
		})
	}

	private func poster(_ req: HTTPRequest) -> HTTPResponse {
		let name = (req.parameters["size"] ?? "").replacingOccurrences(of: ".jpg", with: "")
		guard let meta, let id = Int64(req.parameters["meta"] ?? ""), ["tn", "sm"].contains(name), let size = RenditionSize.named(name) else {
			return HTTPResponse(status: .notFound)
		}
		return jpeg(meta.posterFile(id, name), size, req)
	}

	private func thumb(_ req: HTTPRequest) async -> HTTPResponse {
		guard let size = RenditionSize.named((req.parameters["size"] ?? "").replacingOccurrences(of: ".jpg", with: "")),
		      let obj = catalog.media(Substring(req.parameters["item"] ?? "")),
		      let url = await thumbnails.get(obj, size) else { return HTTPResponse(status: .notFound) }
		return jpeg(url, size, req)
	}

	/// A cached rendition; the cache lives outside the libraries and is addressed by id only.
	private func jpeg(_ url: URL, _ size: RenditionSize, _ req: HTTPRequest) -> HTTPResponse {
		guard let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) else {
			return HTTPResponse(status: .notFound)
		}
		var h: HTTPHeaders = [.contentType: "image/jpeg", .cacheControl: "max-age=86400", .contentLength: String(bytes), .transferMode: "Interactive"]
		if req.headers[.getContentFeatures] == "1" { h[.contentFeatures] = size.contentFeatures }
		if req.method == .head { return HTTPResponse(status: .ok, headers: h) }
		return HTTPResponse(status: .ok, headers: h, body: .file(path: url.path, offset: 0, length: Int64(bytes)))
	}

	// MARK: -

	private static func renderIcons(from url: URL) -> [Int: Data] {
		guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [:] }
		var out: [Int: Data] = [:]
		for size in [48, 120, 256] {
			let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: size]
			let largest = (0..<CGImageSourceGetCount(src)).max { a, b in
				pixelWidth(src, a) < pixelWidth(src, b)
			} ?? 0
			guard let img = CGImageSourceCreateThumbnailAtIndex(src, largest, opts as CFDictionary) else { continue }
			let data = NSMutableData()
			guard let dst = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { continue }
			CGImageDestinationAddImage(dst, img, nil)
			if CGImageDestinationFinalize(dst) { out[size] = data as Data }
		}
		return out
	}

	private static func pixelWidth(_ src: CGImageSource, _ i: Int) -> Int {
		(CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any])?[kCGImagePropertyPixelWidth] as? Int ?? 0
	}
}

nonisolated private func xml(_ s: String) -> HTTPResponse {
	.text(s, type: #"text/xml; charset="utf-8""#)
}

nonisolated private func fault(_ e: UPnPError) -> HTTPResponse {
	.text(SOAP.fault(e), type: #"text/xml; charset="utf-8""#, status: .internalServerError)
}

nonisolated extension Optional where Wrapped == String {
	var nonEmpty: String? {
		guard let s = self?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
		return s
	}
}
