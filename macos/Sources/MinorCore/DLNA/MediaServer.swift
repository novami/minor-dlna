import Foundation
import HTTPTypes
import Hummingbird
import ImageIO
import Logging
import NIOCore
import ServiceLifecycle
import UniformTypeIdentifiers

public struct ServerConfig: Sendable, Equatable {
	public var name: String
	public var uuid: UUID
	public var port: Int
	public var libraries: [Library]
	public var version: String
	/// Image the device icons are rendered from (the app's .icns).
	public var iconURL: URL?
	public var databaseURL: URL
	public var transcode: TranscodeSettings
	public var remote: RemoteSettings
	public var metadata: Bool

	public init(settings: Settings, version: String, iconURL: URL?, databaseURL: URL = Store.defaultURL) {
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
	}
}

public enum ServerState: Sendable, Equatable {
	case stopped
	case starting
	case running(port: Int, addresses: [String])
	case failed(String)
}

/// Runs the HTTP server and SSDP for one configuration; start() again to apply a new one.
public actor MediaServer {
	/// State changes in order; consume from one task.
	public nonisolated let states: AsyncStream<ServerState>
	private let continuation: AsyncStream<ServerState>.Continuation
	private var group: ServiceGroup?
	private var task: Task<Void, Never>?
	/// Kept open across restarts.
	private var store: (url: URL, store: Store)?
	private var running: (routes: Routes, scanner: LibraryScanner, libraries: [IndexedLibrary])?
	/// Outlives restarts, so web users stay logged in.
	private let web = WebAccess()

	public init() { (states, continuation) = AsyncStream.makeStream() }

	private nonisolated func onState(_ s: ServerState) { continuation.yield(s) }

	public func start(_ config: ServerConfig) async {
		await stop()
		onState(.starting)
		var logger = Logger(label: "minordlna")
		logger.logLevel = .warning
		let ssdp = SSDPService(uuid: config.uuid.uuidString.lowercased(), port: config.port, serverHeader: Self.serverHeader(config.version),
		                       services: [Descriptions.cdsType, Descriptions.cmsType])
		let store: Store, libraries: [IndexedLibrary]
		do {
			store = try openStore(config.databaseURL)
			let ids = try store.syncLibraries(config.libraries)
			libraries = config.libraries.compactMap { l in ids[l.id].map { IndexedLibrary(id: $0, library: l) } }
		} catch {
			Log.server.error("index unavailable: \(error, privacy: .public)")
			onState(.failed("Index knihovny nejde otevřít: \(error)"))
			return
		}
		web.configure(config.remote)
		var r = Routes(config: config, store: store, libraries: libraries, web: web)
		let cds = r.cds
		r.tv = TVController(store: store, catalog: r.catalog, port: config.port, profiles: r.profiles, transcode: r.transcoder.available) {
			_ = try? store.bumpUpdateID()
			Task { await cds.notifyAll() }
		}
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
		let app = Application(
			router: routes.router(),
			configuration: .init(address: .hostname("0.0.0.0", port: config.port), serverName: Self.serverHeader(config.version)),
			services: [ssdp],
			onServerRunning: { _ in
				onState(.running(port: config.port, addresses: LANInterface.all().map(\.ip)))
				Log.server.info("listening on port \(config.port)")
			},
			logger: logger
		)
		let group = ServiceGroup(configuration: .init(services: [
			.init(service: app),
			.init(service: scanner, successTerminationBehavior: .ignore),
		] + (meta.map { [.init(service: $0, successTerminationBehavior: .ignore)] } ?? [])
			+ (routes.tv.map { [.init(service: $0, successTerminationBehavior: .ignore)] } ?? []), logger: logger))
		self.group = group
		running = (routes, scanner, libraries)
		task = Task {
			do {
				try await group.run()
				onState(.stopped)
			} catch {
				Log.server.error("server failed: \(error, privacy: .public)")
				onState(.failed(Self.describe(error, port: config.port)))
			}
		}
	}

	private func openStore(_ url: URL) throws -> Store {
		if let store, store.url == url { return store.store }
		let s = try Store(url: url)
		store = (url, s)
		return s
	}

	public func stop() async {
		guard let group, let task else { return }
		await group.triggerGracefulShutdown()
		await task.value
		self.group = nil
		self.task = nil
		running = nil
	}

	/// nil while the server is not running.
	public func status() -> ServerStatus? {
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
	public func setRemote(_ remote: RemoteSettings) { web.configure(remote) }

	// MARK: Metadata by hand; nil or empty while the server or metadata is off.

	public func metadataEntries() -> [MetaEntry] { (try? running?.routes.meta?.entries()) ?? [] }

	public func metadataSearch(_ id: Int64, _ query: String) async throws -> [MetaCandidate] {
		guard let meta = running?.routes.meta else { return [] }
		return try await meta.search(id, query)
	}

	/// nil wikidata: no metadata for the title.
	public func metadataSet(_ id: Int64, wikidata: String?) async throws {
		try await running?.routes.meta?.set(id, wikidata: wikidata)
	}

	public func metadataRematch(_ id: Int64) throws { try running?.routes.meta?.rematch(id) }

	/// Deletes thumbnails and posters; posters are downloaded again right away.
	public func clearCache() throws {
		try CacheStorage.clear()
		guard let meta = running?.routes.meta else { return }
		try meta.refetchMissingPosters()
		meta.kick()
	}

	/// Applies hand-picked client profiles without a restart.
	// MARK: Library

	/// A container's entries; nil when it does not exist (anymore).
	public func browse(_ id: String) -> BrowsePage? { try? running?.routes.catalog.page(id) }

	public func search(_ query: String) -> [BrowseEntry] { running?.routes.catalog.search(query).map(BrowseEntry.init) ?? [] }

	// MARK: Play on TV

	private var tv: TVController {
		get throws {
			guard let tv = running?.routes.tv else { throw TVError("Server neběží.") }
			return tv
		}
	}

	public func tvDevices() async -> [Renderer] { await running?.routes.tv?.devices() ?? [] }
	public func tvSearch() async throws -> [Renderer] { try await tv.search() }
	public func tvWake(_ udn: String) async throws { try await tv.wake(udn) }
	public func tvStatus() async -> TVStatus? { await running?.routes.tv?.status() }
	public func tvCommand(_ c: TVCommand) async throws { try await tv.command(c) }

	/// fromMs > 0 resumes a few seconds before it.
	public func tvPlay(udn: String, itemID: String, fromMs: Int = 0) async throws {
		try await tv.play(udn: udn, id: itemID, fromMs: fromMs)
	}

	public func chooseProfiles(_ clients: [String: String]) {
		running?.routes.profiles.choose(clients)
	}

	static func serverHeader(_ version: String) -> String {
		let v = ProcessInfo.processInfo.operatingSystemVersion
		return "macOS/\(v.majorVersion).\(v.minorVersion) UPnP/1.0 DLNADOC/1.50 MinorDLNA/\(version)"
	}

	private static func describe(_ error: any Error, port: Int) -> String {
		if let e = error as? IOError, e.errnoCode == EADDRINUSE { return "Port \(port) už používá jiná aplikace." }
		if let e = error as? IOError, e.errnoCode == EACCES { return "Port \(port) není povolený." }
		return "Server se nepodařilo spustit: \(error)"
	}
}

struct DLNAContext: RequestContext, RemoteAddressRequestContext {
	var coreContext: CoreRequestContextStorage
	let remoteAddress: SocketAddress?

	init(source: ApplicationRequestContextSource) {
		coreContext = .init(source: source)
		remoteAddress = source.channel.remoteAddress
	}
}

/// Rejects clients outside private networks.
struct AccessMiddleware: RouterMiddleware {
	func handle(_ request: Request, context: DLNAContext, next: (Request, DLNAContext) async throws -> Response) async throws -> Response {
		guard let ip = context.remoteAddress?.ipAddress, AccessPolicy.allows(ip) else { return Response(status: .forbidden) }
		return try await next(request, context)
	}
}

extension HTTPField.Name {
	// Exact case: some TVs match DLNA headers case-sensitively.
	static let transferMode = Self("transferMode.dlna.org")!
	static let contentFeatures = Self("contentFeatures.dlna.org")!
	static let getContentFeatures = Self("getcontentFeatures.dlna.org")!
	static let soapAction = Self("SOAPAction")!
	static let sid = Self("SID")!
	static let nt = Self("NT")!
	static let callback = Self("CALLBACK")!
	static let timeout = Self("TIMEOUT")!
	static let ext = Self("EXT")!
	static let timeSeekRange = Self("TimeSeekRange.dlna.org")!
	static let captionInfo = Self("CaptionInfo.sec")!
	static let avClientInfo = Self("X-AV-Client-Info")!
}

struct Routes: Sendable {
	let config: ServerConfig
	let catalog: LibraryCatalog
	let store: Store
	let cds: Eventer
	let cms: Eventer
	let icons: [Int: Data]
	let files = FileIO()
	let thumbnails = Thumbnails()
	let transcoder: Transcoder
	let profiles: ClientProfiles
	let web: WebRoutes
	/// Set before the server starts; nil when metadata is off.
	var meta: MetadataService?
	/// Set before the server starts.
	var tv: TVController?

	init(config: ServerConfig, store: Store, libraries: [IndexedLibrary], web access: WebAccess = WebAccess()) {
		self.config = config
		self.store = store
		transcoder = Transcoder(hardware: config.transcode.hardware, maxSessions: config.transcode.maxSessions)
		profiles = ClientProfiles(dts: config.transcode.dts, chosen: config.transcode.clients)
		catalog = LibraryCatalog(db: store.reader, libraries: libraries, videoArt: thumbnails.ffmpeg != nil)
		cds = Eventer { [("SystemUpdateID", String(store.updateID())), ("ContainerUpdateIDs", "")] }
		cms = Eventer { [("SourceProtocolInfo", MediaFormat.sourceProtocolInfo), ("SinkProtocolInfo", ""), ("CurrentConnectionIDs", "0")] }
		icons = config.iconURL.map(Self.renderIcons) ?? [:]
		web = WebRoutes(access: access) { [config, store] in
			let counts = store.counts()
			return .init(name: config.name, version: config.version, libraries: libraries.map {
				.init(name: $0.library.name, type: $0.type.rawValue, items: counts[$0.id]?.items ?? 0)
			})
		}
	}

	func router() -> Router<DLNAContext> {
		let r = Router(context: DLNAContext.self)
		r.add(middleware: AccessMiddleware())
		r.get("/description.xml") { _, _ in
			xml(Descriptions.device(name: config.name, version: config.version, uuid: config.uuid.uuidString.lowercased()))
		}
		r.get("/cds.xml") { _, _ in xml(Descriptions.cds) }
		r.get("/cms.xml") { _, _ in xml(Descriptions.cms) }
		r.post("/cds/control") { req, ctx in try await control(req, ctx, serviceType: Descriptions.cdsType, handler: cdsAction) }
		r.post("/cms/control") { req, ctx in try await control(req, ctx, serviceType: Descriptions.cmsType, handler: cmsAction) }
		for (path, ev) in [("/cds/event", cds), ("/cms/event", cms)] {
			r.on(RouterPath(path), method: HTTPRequest.Method("SUBSCRIBE")!) { req, ctx in await subscribe(req, ctx, ev) }
			r.on(RouterPath(path), method: HTTPRequest.Method("UNSUBSCRIBE")!) { req, _ in
				Response(status: await ev.unsubscribe(sid: req.headers[.sid]) ? .ok : .preconditionFailed)
			}
		}
		r.get("/icon/:size") { _, ctx in
			guard let size = Int(ctx.parameters.get("size")?.replacingOccurrences(of: ".png", with: "") ?? ""), let png = icons[size] else {
				return Response(status: .notFound)
			}
			return Response(status: .ok, headers: [.contentType: "image/png"], body: .init(byteBuffer: ByteBuffer(bytes: png)))
		}
		r.get("/media/:token") { req, ctx in try await media(req, ctx) }
		r.head("/media/:token") { req, ctx in try await media(req, ctx) }
		r.get("/transcode/:item/:file") { req, ctx in await transcode(req, ctx) }
		r.head("/transcode/:item/:file") { req, ctx in await transcode(req, ctx) }
		r.get("/subs/:file") { req, ctx in try await subtitles(req, ctx) }
		r.head("/subs/:file") { req, ctx in try await subtitles(req, ctx) }
		r.get("/poster/:meta/:size") { req, ctx in try await poster(req, ctx) }
		r.head("/poster/:meta/:size") { req, ctx in try await poster(req, ctx) }
		r.get("/thumb/:item/:size") { req, ctx in try await thumb(req, ctx) }
		r.head("/thumb/:item/:size") { req, ctx in try await thumb(req, ctx) }
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

	private func client(_ req: Request, _ ctx: DLNAContext) -> Client {
		let baseURL = "http://" + (req.head.authority ?? "localhost:\(config.port)")
		guard transcoder.available else { return Client(baseURL: baseURL) }
		// Older Sony TVs name themselves only in X-AV-Client-Info.
		let ident = (req.headers[.userAgent] ?? "") + " " + (req.headers[.avClientInfo] ?? "")
		return Client(baseURL: baseURL, profile: profiles.profile(ip: ctx.remoteAddress?.ipAddress ?? "", ident: ident))
	}

	private func control(_ req: Request, _ ctx: DLNAContext, serviceType: String, handler: Action) async throws -> Response {
		let body = try await req.body.collect(upTo: 1 << 20)
		guard let call = SOAP.parse(Data(body.readableBytesView), soapAction: req.headers[.soapAction]) else {
			return fault(.invalidArgs)
		}
		do {
			let out = try handler(call, client(req, ctx))
			var r = xml(SOAP.response(action: call.action, serviceType: serviceType, args: out))
			r.headers[.ext] = ""
			return r
		} catch {
			Log.server.debug("soap fault \(call.action, privacy: .public): \(error.code)")
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
		default: throw .invalidAction
		}
	}

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

	private func subscribe(_ req: Request, _ ctx: DLNAContext, _ ev: Eventer) async -> Response {
		let outcome = await ev.subscribe(remoteIP: ctx.remoteAddress?.ipAddress ?? "", sid: req.headers[.sid], nt: req.headers[.nt],
		                                 callback: req.headers[.callback], timeout: req.headers[.timeout])
		guard case let .ok(sid, timeout) = outcome else { return Response(status: .preconditionFailed) }
		return Response(status: .ok, headers: [.sid: sid, .timeout: "Second-\(timeout)"])
	}

	// MARK: Media

	private func media(_ req: Request, _ ctx: DLNAContext) async throws -> Response {
		guard let obj = catalog.media(Substring(ctx.parameters.get("token") ?? "")), let path = obj.path, let format = obj.format else { return Response(status: .notFound) }
		var h: HTTPFields = [.contentType: format.mime, .acceptRanges: "bytes"]
		let mode = req.headers[.transferMode]
		h[.transferMode] = ["Streaming", "Interactive", "Background"].contains(mode ?? "") ? mode : format.transferMode
		if req.headers[.getContentFeatures] == "1" { h[.contentFeatures] = format.contentFeatures }
		if let m = obj.modified { h[.lastModified] = httpDate.string(from: m) }
		captions(obj, req, &h)

		var status = HTTPResponse.Status.ok
		var range: ClosedRange<Int64> = 0...max(obj.size - 1, 0)
		if let header = req.headers[.range] {
			guard let r = ByteRange.parse(header, size: obj.size) else {
				h[.contentRange] = "bytes */\(obj.size)"
				return Response(status: .rangeNotSatisfiable, headers: h)
			}
			range = r
			status = .partialContent
			h[.contentRange] = "bytes \(r.lowerBound)-\(r.upperBound)/\(obj.size)"
		}
		let length = obj.size == 0 ? 0 : range.upperBound - range.lowerBound + 1
		h[.contentLength] = String(length)
		if req.method == .head || length == 0 { return Response(status: status, headers: h) }
		if let remote = ctx.remoteAddress?.ipAddress {
			Log.server.info("stream \(obj.title, privacy: .public) to \(remote, privacy: .public) range \(req.headers[.range] ?? "-", privacy: .public)")
		}
		let body = try await files.loadFile(path: path, range: Int(range.lowerBound)...Int(range.upperBound), context: ctx)
		return Response(status: status, headers: h, body: body)
	}

	/// Announces external subtitles to the TV player.
	private func captions(_ o: CatalogObject, _ req: Request, _ h: inout HTTPFields) {
		guard o.subtitle != nil, let n = Int64(o.id.dropFirst()) else { return }
		h[.captionInfo] = "http://" + (req.head.authority ?? "localhost:\(config.port)") + Subtitles.path(item: n)
	}

	private func subtitles(_ req: Request, _ ctx: DLNAContext) async throws -> Response {
		let name = ctx.parameters.get("file") ?? ""
		guard name.hasSuffix(".srt"), let obj = catalog.media(Substring(name.dropLast(4))), let path = obj.subtitle,
		      let fh = FileHandle(forReadingAtPath: path) else { return Response(status: .notFound) }
		defer { try? fh.close() }
		let data = Subtitles.utf8(try fh.read(upToCount: 5 << 20) ?? Data())
		let h: HTTPFields = [.contentType: "text/srt; charset=utf-8", .contentLength: String(data.count)]
		if req.method == .head { return Response(status: .ok, headers: h) }
		return Response(status: .ok, headers: h, body: .init(byteBuffer: ByteBuffer(bytes: data)))
	}

	private func transcode(_ req: Request, _ ctx: DLNAContext) async -> Response {
		let file = ctx.parameters.get("file") ?? ""
		guard transcoder.available, let plan = Plan(key: file.prefix { $0 != "." }),
		      let item = ctx.parameters.get("item"), Int64(item) != nil, let obj = catalog.media(Substring(item)),
		      let path = obj.path, let kind = obj.format?.kind, kind == .video || kind == .audio,
		      plan.video == nil || kind == .video else { return Response(status: .notFound) }

		var h: HTTPFields = [.contentType: plan.mime, .transferMode: "Streaming"]
		if req.headers[.getContentFeatures] == "1" { h[.contentFeatures] = Plan.contentFeatures }
		captions(obj, req, &h)
		var start = 0.0
		let dur = Double(obj.durationMs ?? 0) / 1000
		if let tsr = req.headers[.timeSeekRange] {
			guard let from = Transcoder.parseNPT(tsr), dur <= 0 || from < dur else { return Response(status: .rangeNotSatisfiable, headers: h) }
			start = from
			// A copied stream starts at the keyframe before, and the reply says where it really starts.
			if plan.video != nil, plan.video == .copy || plan.audio == .copy { start = await transcoder.keyframe(path, before: start) }
			if dur > 0 { h[.timeSeekRange] = String(format: "npt=%.3f-%.3f/%.3f", start, dur, dur) }
		}
		if req.method == .head { return Response(status: .ok, headers: h) }
		guard let lease = await transcoder.acquire() else {
			Log.server.warning("transcode refused, all sessions busy: \(obj.title, privacy: .public)")
			return Response(status: .serviceUnavailable)
		}
		let args = Transcoder.args(plan, path: path, start: start, hardware: transcoder.hardware,
		                           decodesInHardware: Transcoder.decodesInHardware(obj))
		let session = TranscodeSession(title: obj.title, client: ctx.remoteAddress?.ipAddress ?? "-", plan: plan.key)
		return Response(status: .ok, headers: h, body: ResponseBody { [transcoder, start] writer in
			try await transcoder.stream(args, session: session, from: start, lease: lease, to: &writer)
		})
	}

	private func poster(_ req: Request, _ ctx: DLNAContext) async throws -> Response {
		let name = (ctx.parameters.get("size") ?? "").replacingOccurrences(of: ".jpg", with: "")
		guard let meta, let id = Int64(ctx.parameters.get("meta") ?? ""), ["tn", "sm"].contains(name), let size = RenditionSize.named(name) else {
			return Response(status: .notFound)
		}
		let url = meta.posterFile(id, name)
		guard let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil else { return Response(status: .notFound) }
		var h: HTTPFields = [.contentType: "image/jpeg", .cacheControl: "max-age=86400", .contentLength: String(bytes), .transferMode: "Interactive"]
		if req.headers[.getContentFeatures] == "1" { h[.contentFeatures] = size.contentFeatures }
		if req.method == .head { return Response(status: .ok, headers: h) }
		return Response(status: .ok, headers: h, body: try await files.loadFile(path: url.path, context: ctx))
	}

	private func thumb(_ req: Request, _ ctx: DLNAContext) async throws -> Response {
		guard let size = RenditionSize.named((ctx.parameters.get("size") ?? "").replacingOccurrences(of: ".jpg", with: "")),
		      let obj = catalog.media(Substring(ctx.parameters.get("item") ?? "")),
		      let url = await thumbnails.get(obj, size),
		      let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
		else { return Response(status: .notFound) }
		var h: HTTPFields = [.contentType: "image/jpeg", .cacheControl: "max-age=86400", .contentLength: String(bytes), .transferMode: "Interactive"]
		if req.headers[.getContentFeatures] == "1" { h[.contentFeatures] = size.contentFeatures }
		if req.method == .head { return Response(status: .ok, headers: h) }
		return Response(status: .ok, headers: h, body: try await files.loadFile(path: url.path, context: ctx))
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

private func xml(_ s: String) -> Response {
	Response(status: .ok, headers: [.contentType: #"text/xml; charset="utf-8""#], body: .init(byteBuffer: ByteBuffer(string: s)))
}

private func fault(_ e: UPnPError) -> Response {
	Response(status: .internalServerError, headers: [.contentType: #"text/xml; charset="utf-8""#],
	         body: .init(byteBuffer: ByteBuffer(string: SOAP.fault(e))))
}

enum ByteRange {
	/// Parses a single "bytes=a-b", "bytes=a-" or "bytes=-n" range; nil when it cannot be satisfied.
	static func parse(_ header: String, size: Int64) -> ClosedRange<Int64>? {
		let h = header.trimmingCharacters(in: .whitespaces)
		guard h.lowercased().hasPrefix("bytes="), size > 0 else { return nil }
		let spec = h.dropFirst(6).split(separator: ",").first?.trimmingCharacters(in: .whitespaces) ?? ""
		let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
		guard parts.count == 2 else { return nil }
		if parts[0].isEmpty { // suffix
			guard let n = Int64(parts[1]), n > 0 else { return nil }
			return max(size - n, 0)...(size - 1)
		}
		guard let start = Int64(parts[0]), start < size else { return nil }
		if parts[1].isEmpty { return start...(size - 1) }
		guard let end = Int64(parts[1]), end >= start else { return nil }
		return start...min(end, size - 1)
	}
}

extension Optional where Wrapped == String {
	var nonEmpty: String? {
		guard let s = self?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
		return s
	}
}
