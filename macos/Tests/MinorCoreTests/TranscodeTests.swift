import Foundation
import Hummingbird
import HummingbirdTesting
import Testing
@testable import MinorCore

private func media(_ container: String, _ video: String?, _ audio: String?, kind: String = "x.mkv", pix: String = "yuv420p",
                   channels: Int = 2) -> CatalogObject {
	var o = CatalogObject(id: "I1", parentID: "0", title: "x", isContainer: false)
	o.format = MediaFormat.lookup(kind)
	o.container = container
	o.videoCodec = video
	o.audioCodec = audio
	o.pixFmt = pix
	o.channels = channels
	return o
}

@Test func decideForLG() throws {
	let lg = try #require(Profile.named(Profile.detectID("Mozilla/5.0 (Web0S; Linux/SmartTV) webOS"), dts: false))
	#expect(lg.name == "lg")
	#expect(Plan.decide(lg, media("matroska,webm", "hevc", "eac3")) == .direct)
	#expect(Plan.decide(lg, media("matroska,webm", "h264", "truehd", channels: 8)) == Plan(video: .copy, audio: .ac3))
	#expect(Plan.decide(lg, media("matroska,webm", "h264", "dts")) == Plan(video: .copy, audio: .aac))
	#expect(Plan.decide(Profile.named("lg", dts: true)!, media("mov,mp4", "h264", "dts")) == .direct)
	#expect(Plan.decide(lg, media("asf", "h264", "ac3")) == Plan(video: .copy, audio: .copy))
	#expect(Plan.decide(lg, media("matroska,webm", "h264", "yuv420p10le", pix: "yuv420p10le")).video == .h264)
	#expect(Plan.decide(lg, media("matroska,webm", "vp9", "wmav2")) == Plan(video: .h264, audio: .aac))
	#expect(Plan.decide(lg, media("ape", nil, "ape", kind: "x.flac")) == Plan(audio: .flac))
	#expect(Plan.decide(lg, media("", nil, nil)) == .direct)
	#expect(Plan.decide(.generic, media("matroska", "h264", "truehd")) == .direct)
}

@Test func chosenProfileWins() {
	let p = ClientProfiles(dts: true, chosen: ["10.0.0.2": "generic"])
	#expect(p.profile(ip: "10.0.0.1", ident: "webOS TV").name == "lg")
	#expect(p.profile(ip: "10.0.0.2", ident: "webOS TV").name == "generic")
	p.choose([:])
	#expect(p.profile(ip: "10.0.0.2", ident: "").name == "lg") // detection remembers the earlier ident
	#expect(p.list().map(\.ip).sorted() == ["10.0.0.1", "10.0.0.2"])
}

@Test func planKeysAndNPT() {
	#expect(Plan(key: "copy-ac3") == Plan(video: .copy, audio: .ac3))
	#expect(Plan(key: "x-flac") == Plan(audio: .flac))
	for bad in ["x-x", "copy", "h265-aac", "copy-aac-x", ""] { #expect(Plan(key: bad) == nil) }
	#expect(Transcoder.parseNPT("npt=123.5-") == 123.5)
	#expect(Transcoder.parseNPT("npt=0:02:03.5-0:03:00") == 123.5)
	#expect(Transcoder.parseNPT("npt=now-") == 0)
	#expect(Transcoder.parseNPT("bytes=0-") == nil)
	#expect(Transcoder.parseNPT("npt=1:x-") == nil)
}

@Test func subtitlesToUTF8() {
	let cp1250 = Data([0x50, 0xF8, 0xED, 0x6C, 0x69, 0x9A]) // "Příliš"
	#expect(String(decoding: Subtitles.utf8(cp1250), as: UTF8.self) == "Příliš")
	#expect(Subtitles.utf8(Data([0xEF, 0xBB, 0xBF]) + Data("Žluť".utf8)) == Data("Žluť".utf8))
}

@Test(.enabled(if: Prober().available && Thumbnails.findFFmpeg() != nil))
func transcodeForLG() async throws {
	let ffmpeg = try #require(Thumbnails.findFFmpeg())
	let dir = FileManager.default.temporaryDirectory.appending(path: "minordlna-\(UUID())")
	try FileManager.default.createDirectory(at: dir.appending(path: "Filmy"), withIntermediateDirectories: true)
	defer { try? FileManager.default.removeItem(at: dir) }
	// WMA audio in Matroska: LG plays the video but not the audio, so the video is copied and the audio converted.
	_ = try await Prober.run(ffmpeg, ["-v", "error", "-f", "lavfi", "-i", "testsrc=d=6:s=320x240:r=25", "-f", "lavfi", "-i", "sine=d=6",
	                                  "-c:v", "libx264", "-g", "25", "-c:a", "wmav2", dir.appending(path: "Filmy/Film (2020).mkv").path], timeout: 60)
	try Data([0x31, 0x0A, 0x30, 0x30, 0x3A, 0x30, 0x30, 0x3A, 0x30, 0x31, 0x2C, 0x30, 0x30, 0x30, 0x20, 0x2D, 0x2D, 0x3E, 0x20,
	          0x30, 0x30, 0x3A, 0x30, 0x30, 0x3A, 0x30, 0x32, 0x2C, 0x30, 0x30, 0x30, 0x0A, 0x9A, 0x0A])
		.write(to: dir.appending(path: "Filmy/Film (2020).srt")) // "š" in Windows-1250

	let lib = Library(name: "Filmy", type: .movies, paths: [dir.appending(path: "Filmy").path(percentEncoded: false)
			.replacingOccurrences(of: #"/$"#, with: "", options: .regularExpression)])
	var settings = Settings(name: "Test")
	settings.libraries = [lib]
	let store = try Store(url: dir.appending(path: "index.sqlite"))
	let libs = try store.syncLibraries([lib]).map { IndexedLibrary(id: $0.value, library: lib) }
	let scanner = LibraryScanner(store: store, libraries: libs) { _ in }
	scanner.scanAll(force: true)
	_ = await scanner.probePending(for: .seconds(30))
	let routes = Routes(config: ServerConfig(settings: settings, version: "test", iconURL: nil), store: store, libraries: libs)
	let app = Application(router: routes.router())

	try await app.test(.live) { client in
		let browse = #"<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><u:Browse xmlns:u="urn:schemas-upnp-org:service:ContentDirectory:1"><ObjectID>L\#(libs[0].id)/all</ObjectID><BrowseFlag>BrowseDirectChildren</BrowseFlag><StartingIndex>0</StartingIndex><RequestedCount>10</RequestedCount></u:Browse></s:Body></s:Envelope>"#
		let didl = try await client.execute(uri: "/cds/control", method: .post, headers: [.userAgent: "LG webOS TV"],
		                                    body: ByteBuffer(string: browse)) { String(buffer: $0.body) }
		let item = try #require(didl.firstMatch(of: /\/transcode\/(\d+)\/copy-aac\.ts/)?.1)
		#expect(!didl.contains("/media/\(item)"))
		#expect(didl.contains("sec:CaptionInfoEx") && didl.contains("/subs/\(item).srt"))

		try await client.execute(uri: "/transcode/\(item)/copy-aac.ts", method: .get,
		                         headers: [.timeSeekRange: "npt=2.5-", .getContentFeatures: "1"]) { res in
			#expect(res.status == .ok)
			#expect(res.headers[.contentType] == "video/mpeg")
			#expect(res.headers[.timeSeekRange]?.hasPrefix("npt=2.000-6.0") == true) // keyframe every second
			#expect(res.headers[.captionInfo]?.hasSuffix("/subs/\(item).srt") == true)
			#expect(res.body.readableBytes > 10000 && res.body.getInteger(at: 0, as: UInt8.self) == 0x47)
		}
		try await client.execute(uri: "/transcode/\(item)/h265-aac.ts", method: .get) { #expect($0.status == .notFound) }
		try await client.execute(uri: "/subs/\(item).srt", method: .get) { res in
			#expect(String(buffer: res.body).hasSuffix("š\n"))
		}
	}
}
