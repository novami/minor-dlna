import Foundation
import XCTest
@testable import MinorDLNA

final class TranscodeTests: XCTestCase {
	func testDecideForLG() throws {
		let lg = try XCTUnwrap(Profile.named(Profile.detectID("Mozilla/5.0 (Web0S; Linux/SmartTV) webOS"), dts: false))
		XCTAssertTrue(lg.name == "lg")
		XCTAssertTrue(Plan.decide(lg, media("matroska,webm", "hevc", "eac3")) == .direct)
		XCTAssertTrue(Plan.decide(lg, media("matroska,webm", "h264", "truehd", channels: 8)) == Plan(video: .copy, audio: .ac3))
		XCTAssertTrue(Plan.decide(lg, media("matroska,webm", "h264", "dts")) == Plan(video: .copy, audio: .aac))
		XCTAssertTrue(Plan.decide(Profile.named("lg", dts: true)!, media("mov,mp4", "h264", "dts")) == .direct)
		XCTAssertTrue(Plan.decide(lg, media("asf", "h264", "ac3")) == Plan(video: .copy, audio: .copy))
		XCTAssertTrue(Plan.decide(lg, media("matroska,webm", "h264", "yuv420p10le", pix: "yuv420p10le")).video == .h264)
		XCTAssertTrue(Plan.decide(lg, media("matroska,webm", "vp9", "wmav2")) == Plan(video: .h264, audio: .aac))
		XCTAssertTrue(Plan.decide(lg, media("ape", nil, "ape", kind: "x.flac")) == Plan(audio: .flac))
		XCTAssertTrue(Plan.decide(lg, media("", nil, nil)) == .direct)
		XCTAssertTrue(Plan.decide(.generic, media("matroska", "h264", "truehd")) == .direct)
	}

	func testDetectsBrands() {
		XCTAssertTrue(Profile.detectID("Roku/DVP-12.0 LG") == "roku")
		XCTAssertTrue(Profile.detectID("SEC_HHP_[TV] Samsung Tizen") == "samsung")
		XCTAssertTrue(Profile.detectID("X-AV-Client-Info: BRAVIA") == "sony")
		XCTAssertTrue(Profile.detectID("VLC/3.0") == "generic")
		XCTAssertTrue(Profile.named("samsung", dts: true)?.audioCodecs?.contains("dts") == true)
	}

	func testChosenProfileWins() {
		let p = ClientProfiles(dts: true, chosen: ["10.0.0.2": "generic"])
		XCTAssertTrue(p.profile(ip: "10.0.0.1", ident: "webOS TV").name == "lg")
		XCTAssertTrue(p.profile(ip: "10.0.0.2", ident: "webOS TV").name == "generic")
		p.choose([:])
		XCTAssertTrue(p.profile(ip: "10.0.0.2", ident: "").name == "lg") // detection remembers the earlier ident
		XCTAssertTrue(p.list().map(\.ip).sorted() == ["10.0.0.1", "10.0.0.2"])
	}

	func testPlanKeysAndNPT() {
		XCTAssertTrue(Plan(key: "copy-ac3") == Plan(video: .copy, audio: .ac3))
		XCTAssertTrue(Plan(key: "x-flac") == Plan(audio: .flac))
		for bad in ["x-x", "copy", "h265-aac", "copy-aac-x", ""] { XCTAssertTrue(Plan(key: bad) == nil) }
		XCTAssertTrue(Transcoder.parseNPT("npt=123.5-") == 123.5)
		XCTAssertTrue(Transcoder.parseNPT("npt=0:02:03.5-0:03:00") == 123.5)
		XCTAssertTrue(Transcoder.parseNPT("npt=now-") == 0)
		XCTAssertTrue(Transcoder.parseNPT("bytes=0-") == nil)
		XCTAssertTrue(Transcoder.parseNPT("npt=1:x-") == nil)
	}

	func testSubtitlesToUTF8() {
		let cp1250 = Data([0x50, 0xF8, 0xED, 0x6C, 0x69, 0x9A]) // "Příliš"
		XCTAssertTrue(String(decoding: Subtitles.utf8(cp1250), as: UTF8.self) == "Příliš")
		XCTAssertTrue(Subtitles.utf8(Data([0xEF, 0xBB, 0xBF]) + Data("Žluť".utf8)) == Data("Žluť".utf8))
	}

	func testTranscodeForLG() async throws {
				let ffmpeg = try XCTUnwrap(Thumbnails.findFFmpeg(), "build the bundled ffmpeg first: scripts/build-ffmpeg.sh")
		let dir = FileManager.default.temporaryDirectory.appending(path: "minordlna-\(UUID())")
		try FileManager.default.createDirectory(at: dir.appending(path: "Filmy"), withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: dir) }
		// WMA audio in Matroska: LG plays the video but not the audio, so the video is copied and the audio converted.
		do {
			_ = try await Prober.run(ffmpeg, ["-v", "error", "-f", "lavfi", "-i", "testsrc=d=6:s=320x240:r=25", "-f", "lavfi", "-i", "sine=d=6",
			                                  "-c:v", "h264_videotoolbox", "-g", "25", "-c:a", "wmav2", dir.appending(path: "Filmy/Film (2020).mkv").path], timeout: 60)
		} catch {
			throw XCTSkip("VideoToolbox cannot encode here (a virtual machine?): \(error)")
		}
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
		let router = routes.router()

		let didl = await call(router, .post, "/cds/control", headers: [.userAgent: "LG webOS TV", HTTPHeaderName("SOAPAction"): #""urn:schemas-upnp-org:service:ContentDirectory:1#Browse""#],
		                      body: soapBrowse("L\(libs[0].id)/all")).text
		let item = try XCTUnwrap(didl.firstMatch(of: /\/transcode\/(\d+)\/copy-aac\.ts/)?.1)
		XCTAssertTrue(!didl.contains("/media/\(item)"))
		XCTAssertTrue(didl.contains("sec:CaptionInfoEx") && didl.contains("/subs/\(item).srt"))

		let ts = await call(router, .get, "/transcode/\(item)/copy-aac.ts", headers: [.timeSeekRange: "npt=2.5-", .getContentFeatures: "1"])
		XCTAssertEqual(ts.status, .ok)
		XCTAssertEqual(ts.headers[.contentType], "video/mpeg")
		XCTAssertTrue(ts.headers[.timeSeekRange]?.hasPrefix("npt=2.000-6.0") == true) // keyframe every second
		XCTAssertTrue(ts.headers[.captionInfo]?.hasSuffix("/subs/\(item).srt") == true)
		XCTAssertTrue(ts.body.count > 10000 && ts.body.first == 0x47)
		let unknown = await call(router, .get, "/transcode/\(item)/h265-aac.ts")
		XCTAssertEqual(unknown.status, .notFound)
		let subs = await call(router, .get, "/subs/\(item).srt")
		XCTAssertTrue(subs.text.hasSuffix("š\n"))
	}

	func testDecideForBrowser() {
		XCTAssertTrue(Plan.decideBrowser(media("mov,mp4,m4a", "h264", "aac", kind: "x.mp4"), hevc: false) == .direct)
		XCTAssertTrue(Plan.decideBrowser(media("matroska,webm", "h264", "ac3"), hevc: false) == Plan(video: .copy, audio: .aac))
		XCTAssertTrue(Plan.decideBrowser(media("mov,mp4", "hevc", "aac", kind: "x.mp4"), hevc: false) == Plan(video: .h264, audio: .copy))
		XCTAssertTrue(Plan.decideBrowser(media("mov,mp4", "hevc", "aac", kind: "x.mp4"), hevc: true) == .direct)
		XCTAssertTrue(Plan.decideBrowser(media("matroska", "h264", nil, pix: "yuv420p10le"), hevc: false) == Plan(video: .h264))
		XCTAssertTrue(Plan.decideBrowser(media("flac", nil, "flac", kind: "x.flac"), hevc: false) == .direct)
		XCTAssertTrue(Plan.decideBrowser(media("mov,mp4,m4a", nil, "alac", kind: "x.m4a"), hevc: false) == Plan(audio: .aac))
	}

	func testBrowserStreamDetails() {
		// Dolby Vision profile 5 level 6 and profile 8 level 13
		XCTAssertTrue(StreamInfo.dvCodec("dvh1", [1, 0, 0x0A, 0x35]) == "dvh1.05.06")
		XCTAssertTrue(StreamInfo.dvCodec("dvh1", [1, 0, 0x10, 0x6D]) == "dvh1.08.13")
		// Main 10, high tier off, level 5.1
		XCTAssertTrue(StreamInfo.hevcCodec("hvc1", [1, 0x02, 0x20, 0, 0, 0, 0xB0, 0, 0, 0, 0, 0, 153]) == "hvc1.2.4.L153.B0")
		XCTAssertTrue(HDR(probe: "color_transfer=unknown\ndv_profile=5\n") == HDR(transfer: "smpte2084", dvProfile: 5))

		let srt = Data("1\r\n00:00:05,000 --> 00:00:08,500\r\nAhoj\r\n\r\n2\r\n00:01:00,000 --> 00:01:02,000\r\nSvěte\r\n".utf8)
		XCTAssertTrue(Subtitles.vtt(srt, shift: 6) == "WEBVTT\n\n00:00:00.000 --> 00:00:02.500\nAhoj\n\n00:00:54.000 --> 00:00:56.000\nSvěte\n\n")
		XCTAssertTrue(!Subtitles.vtt(srt, shift: 9).contains("Ahoj"))

		let m3u8 = "#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXTINF:4.000,\ns00000.m4s\n"
		XCTAssertTrue(!HLSPlaylist.ready(m3u8))
		XCTAssertTrue(HLSPlaylist.ready(m3u8 + "#EXTINF:4.000,\ns00001.m4s\n"))
		XCTAssertTrue(HLSPlaylist.startAtBeginning(m3u8).hasPrefix("#EXTM3U\n#EXT-X-START:TIME-OFFSET=0,PRECISE=YES\n#EXT-X-TARGETDURATION"))
		XCTAssertTrue(HLSSessions.validName("s00012.m4s") && HLSSessions.validName("master.m3u8") && !HLSSessions.validName("../x.m4s"))
	}
}

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
