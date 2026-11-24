import Foundation
import ImageIO
import XCTest
@testable import MinorDLNA

final class MediaTests: XCTestCase {
	func testProbeOutput() throws {
		let json = #"""
		{"streams": [{"codec_type": "audio", "codec_name": "flac", "channels": 2},
		             {"codec_type": "video", "codec_name": "mjpeg", "width": 500, "height": 500, "disposition": {"attached_pic": 1}}],
		 "format": {"format_name": "flac", "duration": "215.250000", "bit_rate": "900000",
		            "tags": {"TITLE": "Píseň", "ARTIST": "Host", "album_artist": "Kapela", "ALBUM": "Album", "track": "03/12", "DATE": "2019-05-01"}}}
		"""#
		let p = try Prober.parse(Data(json.utf8))
		XCTAssertTrue(p.durationMs == 215_250 && p.audioCodec == "flac" && p.videoCodec == nil && p.hasPicture)
		let m = AudioMeta.merge(AudioMeta.fromLayout(rel: "Složka/Jiné/07 Soubor.flac", path: "/nonexistent/x.flac"), p)
		XCTAssertTrue(m.title == "Píseň" && m.artist == "Host" && m.albumArtist == "Kapela" && m.album == "Album")
		XCTAssertTrue(m.track == 3 && m.year == 2019 && m.hasArt)
	}

	func testMusicLayoutWithoutTags() {
		let m = AudioMeta.fromLayout(rel: "Interpret/Deska/02 - Název.m4a", path: "/nonexistent/x.m4a")
		XCTAssertTrue(m.title == "Název" && m.track == 2 && m.album == "Deska" && m.artist == "Interpret" && m.albumArtist == "Interpret")
	}

	func testPhotoExif() throws {
		let url = FileManager.default.temporaryDirectory.appending(path: "minordlna-\(UUID()).jpg")
		defer { try? FileManager.default.removeItem(at: url) }
		let ctx = CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
		                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
		let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
		CGImageDestinationAddImage(dest, ctx.makeImage()!, [
			kCGImagePropertyOrientation: 6,
			kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2021:07:04 18:30:00"],
		] as CFDictionary)
		XCTAssertTrue(CGImageDestinationFinalize(dest))
		let p = try XCTUnwrap(PhotoInfo.read(url.path))
		XCTAssertTrue(p.width == 40 && p.height == 30 && p.orientation == 6)
		let c = Calendar.current.dateComponents([.year, .month, .day, .hour], from: try XCTUnwrap(p.taken))
		XCTAssertTrue(c.year == 2021 && c.month == 7 && c.day == 4 && c.hour == 18)
	}

	func testProbeMusic() async throws {
		let ffmpeg = try XCTUnwrap(FFmpegTools.path("ffmpeg"), "build the bundled ffmpeg first: Scripts/build-ffmpeg.sh")
		XCTAssertTrue(Prober().available)
		let dir = FileManager.default.temporaryDirectory.appending(path: "minordlna-\(UUID())")
		defer { try? FileManager.default.removeItem(at: dir) }
		let root = dir.appending(path: "Hudba")
		try FileManager.default.createDirectory(at: root.appending(path: "Složka/Deska"), withIntermediateDirectories: true)
		for (name, tags) in [("Složka/Deska/01 Bez tagů.m4a", [String]()),
		                     ("Složka/Deska/02 Tagy.m4a", ["artist=Host", "album_artist=Kapela", "album=Album", "title=Píseň", "genre=Rock"])] {
			_ = try await Prober.run(ffmpeg, ["-v", "error", "-f", "lavfi", "-i", "sine=d=1", "-c:a", "aac"]
				+ tags.flatMap { ["-metadata", $0] } + [root.appending(path: name).path], timeout: 30)
		}
		let lib = Library(name: "Hudba", type: .music, paths: [root.path(percentEncoded: false).replacingOccurrences(of: #"/$"#, with: "", options: .regularExpression)])
		let store = try Store(url: dir.appending(path: "index.sqlite"))
		let libs = try store.syncLibraries([lib]).map { IndexedLibrary(id: $0.value, library: lib) }
		let scanner = LibraryScanner(store: store, libraries: libs) { _ in }
		scanner.scanAll(force: true)
		let cat = LibraryCatalog(db: store.reader, libraries: libs)
		XCTAssertTrue(try cat.children("L\(libs[0].id)/artists", start: 0, count: 0).objects.map(\.title) == ["Složka"])

		do { let ok = await scanner.probePending(for: .seconds(30)) == false; XCTAssertTrue(ok) }
		XCTAssertTrue(try cat.children("L\(libs[0].id)/artists", start: 0, count: 0).objects.map(\.title) == ["Kapela", "Složka"])
		let albums = try cat.children("L\(libs[0].id)/albums", start: 0, count: 0).objects
		XCTAssertTrue(albums.map(\.title) == ["Album", "Deska"])
		let track = try XCTUnwrap(try cat.children(albums[0].id, start: 0, count: 0).objects.first)
		XCTAssertTrue(track.title.contains("Píseň") && track.artist == "Host" && (track.durationMs ?? 0) > 900)
		XCTAssertTrue(store.updateID() == 2)
	}

	func testPhotoRenditions() async throws {
		let dir = FileManager.default.temporaryDirectory.appending(path: "minordlna-\(UUID())")
		defer { try? FileManager.default.removeItem(at: dir) }
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		let src = dir.appending(path: "IMG_1.heic")
		try writeImage(src, type: "public.heic", width: 400, height: 300, orientation: 6)
		var o = CatalogObject(id: "I7", parentID: "D1", title: "IMG_1", isContainer: false)
		(o.path, o.format, o.size, o.width, o.height, o.orientation) = (src.path, MediaFormat.lookup("x.heic"), 1, 400, 300, 6)
		o.modified = Date()

		let thumbs = Thumbnails(dir: dir.appending(path: "cache"), ffmpeg: nil)
		for (size, w, h) in [("sm", 300, 400), ("tn", 120, 160)] {
			let got = await thumbs.get(o, RenditionSize.named(size)!)
			let url = try XCTUnwrap(got)
			let p = try XCTUnwrap(PhotoInfo.read(url.path))
			XCTAssertTrue(p.width == w && p.height == h && (p.orientation ?? 1) == 1)
			XCTAssertTrue(CGImageSourceGetType(CGImageSourceCreateWithURL(url as CFURL, nil)!) as String? == "public.jpeg")
		}
		let didl = DIDL.render([o], baseURL: "http://h")
		XCTAssertTrue(didl.contains(#">http://h/thumb/7/lrg.jpg</res><res protocolInfo="http-get:*:image/jpeg:DLNA.ORG_PN=JPEG_SM"#))
		XCTAssertTrue(!didl.contains("/media/"))
	}
}

/// Tags replace the folder layout once probed; the untagged file keeps it.

private func writeImage(_ url: URL, type: String, width: Int, height: Int, orientation: Int) throws {
	let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
	                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
	let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil))
	CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImagePropertyOrientation: orientation] as CFDictionary)
	XCTAssertTrue(CGImageDestinationFinalize(dest))
}

/// A rotated HEIC is served only as upright JPEG renditions, never upscaled.
