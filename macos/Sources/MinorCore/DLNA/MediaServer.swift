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

	public init(settings: Settings, version: String, iconURL: URL?, databaseURL: URL = Store.defaultURL) {
		name = settings.name.trimmingCharacters(in: .whitespaces).isEmpty ? "MinorDLNA" : settings.name
		uuid = settings.uuid
		port = settings.port
		libraries = settings.libraries
		self.version = version
		self.iconURL = iconURL
		self.databaseURL = databaseURL
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
		let routes = Routes(config: config, store: store, libraries: libraries)
		let scanner = LibraryScanner(store: store, libraries: libraries) { _ in Task { await routes.cds.notifyAll() } }
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
		], logger: logger))
		self.group = group
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

	init(config: ServerConfig, store: Store, libraries: [IndexedLibrary]) {
		self.config = config
		self.store = store
		catalog = LibraryCatalog(db: store.reader, libraries: libraries, videoArt: thumbnails.ffmpeg != nil)
		cds = Eventer { [("SystemUpdateID", String(store.updateID())), ("ContainerUpdateIDs", "")] }
		cms = Eventer { [("SourceProtocolInfo", MediaFormat.sourceProtocolInfo), ("SinkProtocolInfo", ""), ("CurrentConnectionIDs", "0")] }
		icons = config.iconURL.map(Self.renderIcons) ?? [:]
	}

	func router() -> Router<DLNAContext> {
		let r = Router(context: DLNAContext.self)
		r.add(middleware: AccessMiddleware())
		r.get("/description.xml") { _, _ in
			xml(Descriptions.device(name: config.name, version: config.version, uuid: config.uuid.uuidString.lowercased()))
		}
		r.get("/cds.xml") { _, _ in xml(Descriptions.cds) }
		r.get("/cms.xml") { _, _ in xml(Descriptions.cms) }
		r.post("/cds/control") { req, _ in try await control(req, serviceType: Descriptions.cdsType, handler: cdsAction) }
		r.post("/cms/control") { req, _ in try await control(req, serviceType: Descriptions.cmsType, handler: cmsAction) }
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
		r.get("/thumb/:item/:size") { req, ctx in try await thumb(req, ctx) }
		r.head("/thumb/:item/:size") { req, ctx in try await thumb(req, ctx) }
		return r
	}

	// MARK: SOAP

	private typealias Action = @Sendable (SOAP.Call, String) throws(UPnPError) -> KeyValuePairs<String, String>

	private func control(_ req: Request, serviceType: String, handler: Action) async throws -> Response {
		let body = try await req.body.collect(upTo: 1 << 20)
		guard let call = SOAP.parse(Data(body.readableBytesView), soapAction: req.headers[.soapAction]) else {
			return fault(.invalidArgs)
		}
		do {
			let out = try handler(call, "http://" + (req.head.authority ?? "localhost:\(config.port)"))
			var r = xml(SOAP.response(action: call.action, serviceType: serviceType, args: out))
			r.headers[.ext] = ""
			return r
		} catch {
			Log.server.debug("soap fault \(call.action, privacy: .public): \(error.code)")
			return fault(error)
		}
	}

	private func cdsAction(_ call: SOAP.Call, baseURL: String) throws(UPnPError) -> KeyValuePairs<String, String> {
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
			return ["Result": DIDL.render(objs, baseURL: baseURL), "NumberReturned": String(objs.count),
			        "TotalMatches": String(total), "UpdateID": String(store.updateID())]
		case "GetSearchCapabilities": return ["SearchCaps": ""]
		case "GetSortCapabilities": return ["SortCaps": "dc:title"]
		case "GetSystemUpdateID": return ["Id": String(store.updateID())]
		default: throw .invalidAction
		}
	}

	private func cmsAction(_ call: SOAP.Call, baseURL _: String) throws(UPnPError) -> KeyValuePairs<String, String> {
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
