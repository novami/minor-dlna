import Foundation
import Hummingbird
import HummingbirdTesting
import Synchronization
import Testing
@testable import MinorCore

@Test func rendererDescriptionAndSOAP() throws {
	let xml = """
	<root xmlns="urn:schemas-upnp-org:device-1-0"><device><deviceType>urn:schemas-upnp-org:device:Basic:1</deviceType><UDN>uuid:root</UDN>
	<deviceList><device><deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType><friendlyName> [LG] webOS TV </friendlyName>
	<manufacturer>LG Electronics</manufacturer><modelName>OLED55C2</modelName><UDN>uuid:tv</UDN><serviceList>
	<service><serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType><controlURL>/rc</controlURL></service>
	<service><serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType><controlURL>upnp/avt</controlURL></service>
	</serviceList></device></deviceList></device></root>
	"""
	let r = try #require(UPnPClient.parseDescription(Data(xml.utf8), location: URL(string: "http://192.168.1.11:1234/desc/d.xml")!))
	#expect(r.udn == "uuid:tv" && r.name == "[LG] webOS TV" && r.ip == "192.168.1.11")
	#expect(r.avTransport == "http://192.168.1.11:1234/desc/upnp/avt" && r.renderingControl == "http://192.168.1.11:1234/rc")

	let fault = #"<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><s:Fault><faultstring>UPnPError</faultstring><detail><UPnPError xmlns="urn:schemas-upnp-org:control-1-0"><errorCode>711</errorCode><errorDescription>Illegal seek target</errorDescription></UPnPError></detail></s:Fault></s:Body></s:Envelope>"#
	#expect(UPnPClient.parseResponse(Data(fault.utf8)).1?.code == 711)
	#expect(UPnPClient.parseTime("1:02:03.500") == 3_723_500 && UPnPClient.parseTime("NOT_IMPLEMENTED") == nil)
	#expect(UPnPClient.formatTime(3_723_500) == "1:02:03")
}

/// A fake TV: the controller loads an episode, saves the position, and goes on to the next one at the end.
@Test func playOnTV() async throws {
	let dir = FileManager.default.temporaryDirectory.appending(path: "minordlna-\(UUID())")
	defer { try? FileManager.default.removeItem(at: dir) }
	let root = dir.appending(path: "Seriály/Show/Season 1")
	try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
	for name in ["01 První.mkv", "02 Druhý.mkv"] { try Data([0]).write(to: root.appending(path: name)) }
	let lib = Library(name: "Seriály", type: .shows, paths: [dir.appending(path: "Seriály").path(percentEncoded: false)
			.replacingOccurrences(of: #"/$"#, with: "", options: .regularExpression)])
	let store = try Store(url: dir.appending(path: "index.sqlite"))
	let libs = try store.syncLibraries([lib]).map { IndexedLibrary(id: $0.value, library: lib) }
	LibraryScanner(store: store, libraries: libs) { _ in }.scanAll(force: true)
	let cat = LibraryCatalog(db: store.reader, libraries: libs)
	let season = try #require(try cat.children("L\(libs[0].id)/shows", start: 0, count: 0).objects.first).id + "/1"
	let eps = try cat.children(season, start: 0, count: 0).objects
	#expect(cat.nextEpisode(eps[0].id)?.id == eps[1].id && cat.nextEpisode(eps[1].id) == nil)
	#expect(cat.search("PRVNI").map(\.id) == [eps[0].id] && cat.search("show").first?.isContainer == true)

	struct TV { var state = "NO_MEDIA_PRESENT", uri = "", pos = "0:00:00", uris: [String] = [], seeks: [String] = [] }
	let tv = Mutex(TV())
	let router = Router()
	router.get("/d.xml") { _, _ in
		"""
		<root><device><deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType><friendlyName>TV</friendlyName><UDN>uuid:tv</UDN>
		<serviceList><service><serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType><controlURL>/avt</controlURL></service></serviceList>
		</device></root>
		"""
	}
	router.post("/avt") { req, _ -> String in
		let call = try #require(SOAP.parse(Data(try await req.body.collect(upTo: 1 << 20).readableBytesView), soapAction: req.headers[.soapAction]))
		let out: KeyValuePairs<String, String> = tv.withLock { t in
			switch call.action {
			case "SetAVTransportURI": t.uri = call.args["CurrentURI"] ?? ""; t.uris.append(t.uri); t.state = "STOPPED"
			case "Play": t.state = "PLAYING"
			case "Stop": t.state = "STOPPED"
			case "Seek": t.seeks.append(call.args["Target"] ?? "")
			default: break
			}
			return call.action == "GetTransportInfo" ? ["CurrentTransportState": t.state]
				: call.action == "GetPositionInfo" ? ["RelTime": t.pos, "TrackDuration": "0:45:00", "TrackURI": t.uri] : [:]
		}
		return SOAP.response(action: call.action, serviceType: UPnPClient.avTransport, args: out)
	}
	let app = Application(router: router, configuration: .init(address: .hostname("127.0.0.1", port: 0)))
	try await app.test(.live) { client in
		try store.saveRenderer(Renderer(udn: "uuid:tv", name: "TV", maker: "", model: "", location: "http://localhost:\(client.port!)/d.xml",
		                                ip: "127.0.0.1", mac: ""))
		let c = TVController(store: store, catalog: cat, port: 8200, profiles: ClientProfiles(dts: false), transcode: false,
		                     pollEvery: .milliseconds(50)) {}
		func until(_ what: String, _ cond: @Sendable () async -> Bool) async throws {
			for _ in 0..<100 where !(await cond()) { try await Task.sleep(for: .milliseconds(50)) }
			let st = await c.status()
			#expect(await cond(), "\(what) \(String(describing: st))")
		}

		try await c.play(udn: "uuid:tv", id: eps[0].id, fromMs: 65000)
		try await until("playing") { await c.status()?.state == .playing && !tv.withLock(\.seeks).isEmpty }
		#expect(tv.withLock(\.seeks) == ["0:01:05"])
		#expect(tv.withLock(\.uris).first?.hasSuffix(DIDL.mediaPath(eps[0])) == true)

		// Played to the end: it counts as watched, and the next episode follows only when that is switched on.
		func playToEnd() async throws {
			tv.withLock { $0.pos = "0:44:50" }
			try await until("near the end") { await c.status()?.positionMs == 2_690_000 }
			tv.withLock { $0.pos = "0:00:00"; $0.state = "STOPPED" }
		}
		try await playToEnd()
		try await until("stopped") { await c.status()?.state == .stopped }
		#expect(tv.withLock(\.uris).count == 1)
		#expect(try cat.metadata(eps[0].id).watched)

		await c.setAutoNext(true)
		try await c.play(udn: "uuid:tv", id: eps[0].id, fromMs: 0)
		try await until("playing again") { await c.status()?.state == .playing }
		try await playToEnd()
		try await until("next episode") { tv.withLock(\.uris).count == 3 }
		#expect(await c.status()?.itemID == eps[1].id)

		tv.withLock { $0.pos = "0:10:00"; $0.state = "PLAYING" }
		try await until("second playing") { await c.status()?.positionMs == 600_000 }
		tv.withLock { $0.pos = "0:10:01" } // not polled yet: stop asks the TV itself
		try await c.command(.stop)
		#expect(await c.status()?.state == .stopped)
		#expect(try cat.metadata(eps[1].id).positionMs == 601_000)
	}
}
