import Foundation
import ImageIO
import Testing
@testable import MinorCore

@Test func probeOutput() throws {
	let json = #"""
	{"streams": [{"codec_type": "audio", "codec_name": "flac", "channels": 2},
	             {"codec_type": "video", "codec_name": "mjpeg", "width": 500, "height": 500, "disposition": {"attached_pic": 1}}],
	 "format": {"format_name": "flac", "duration": "215.250000", "bit_rate": "900000",
	            "tags": {"TITLE": "Píseň", "ARTIST": "Host", "album_artist": "Kapela", "ALBUM": "Album", "track": "03/12", "DATE": "2019-05-01"}}}
	"""#
	let p = try Prober.parse(Data(json.utf8))
	#expect(p.durationMs == 215_250 && p.audioCodec == "flac" && p.videoCodec == nil && p.hasPicture)
	let m = AudioMeta.merge(AudioMeta.fromLayout(rel: "Složka/Jiné/07 Soubor.flac", path: "/nonexistent/x.flac"), p)
	#expect(m.title == "Píseň" && m.artist == "Host" && m.albumArtist == "Kapela" && m.album == "Album")
	#expect(m.track == 3 && m.year == 2019 && m.hasArt)
}

@Test func musicLayoutWithoutTags() {
	let m = AudioMeta.fromLayout(rel: "Interpret/Deska/02 - Název.mp3", path: "/nonexistent/x.mp3")
	#expect(m.title == "Název" && m.track == 2 && m.album == "Deska" && m.artist == "Interpret" && m.albumArtist == "Interpret")
}

@Test func photoExif() throws {
	let url = FileManager.default.temporaryDirectory.appending(path: "minordlna-\(UUID()).jpg")
	defer { try? FileManager.default.removeItem(at: url) }
	let ctx = CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
	                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
	let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
	CGImageDestinationAddImage(dest, ctx.makeImage()!, [
		kCGImagePropertyOrientation: 6,
		kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2021:07:04 18:30:00"],
	] as CFDictionary)
	#expect(CGImageDestinationFinalize(dest))
	let p = try #require(PhotoInfo.read(url.path))
	#expect(p.width == 40 && p.height == 30 && p.orientation == 6)
	let c = Calendar.current.dateComponents([.year, .month, .day, .hour], from: try #require(p.taken))
	#expect(c.year == 2021 && c.month == 7 && c.day == 4 && c.hour == 18)
}

/// Tags replace the folder layout once probed; the untagged file keeps it.
@Test(.enabled(if: Prober().available && FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/ffmpeg")))
func probeMusic() async throws {
	let dir = FileManager.default.temporaryDirectory.appending(path: "minordlna-\(UUID())")
	defer { try? FileManager.default.removeItem(at: dir) }
	let root = dir.appending(path: "Hudba")
	try FileManager.default.createDirectory(at: root.appending(path: "Složka/Deska"), withIntermediateDirectories: true)
	for (name, tags) in [("Složka/Deska/01 Bez tagů.mp3", [String]()),
	                     ("Složka/Deska/02 Tagy.mp3", ["artist=Host", "album_artist=Kapela", "album=Album", "title=Píseň", "genre=Rock"])] {
		_ = try await Prober.run("/opt/homebrew/bin/ffmpeg", ["-v", "error", "-f", "lavfi", "-i", "sine=d=1", "-c:a", "libmp3lame"]
			+ tags.flatMap { ["-metadata", $0] } + [root.appending(path: name).path], timeout: 30)
	}
	let lib = Library(name: "Hudba", type: .music, paths: [root.path(percentEncoded: false).replacingOccurrences(of: #"/$"#, with: "", options: .regularExpression)])
	let store = try Store(url: dir.appending(path: "index.sqlite"))
	let libs = try store.syncLibraries([lib]).map { IndexedLibrary(id: $0.value, library: lib) }
	let scanner = LibraryScanner(store: store, libraries: libs) { _ in }
	scanner.scanAll(force: true)
	let cat = LibraryCatalog(db: store.reader, libraries: libs)
	#expect(try cat.children("L\(libs[0].id)/artists", start: 0, count: 0).objects.map(\.title) == ["Složka"])

	#expect(await scanner.probePending(for: .seconds(30)) == false)
	#expect(try cat.children("L\(libs[0].id)/artists", start: 0, count: 0).objects.map(\.title) == ["Kapela", "Složka"])
	let albums = try cat.children("L\(libs[0].id)/albums", start: 0, count: 0).objects
	#expect(albums.map(\.title) == ["Album", "Deska"])
	let track = try #require(try cat.children(albums[0].id, start: 0, count: 0).objects.first)
	#expect(track.title.contains("Píseň") && track.artist == "Host" && (track.durationMs ?? 0) > 900)
	#expect(store.updateID() == 2)
}
