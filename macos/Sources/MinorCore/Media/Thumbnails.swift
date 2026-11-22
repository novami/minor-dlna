import Foundation
import ImageIO
import Synchronization
import UniformTypeIdentifiers

/// A DLNA JPEG profile with its bounding box (landscape; portrait swaps).
struct RenditionSize: Sendable, Equatable {
	let name: String
	let profile: String
	let width: Int
	let height: Int

	static let all = [
		RenditionSize(name: "tn", profile: "JPEG_TN", width: 160, height: 160),
		RenditionSize(name: "sm", profile: "JPEG_SM", width: 640, height: 480),
		RenditionSize(name: "lrg", profile: "JPEG_LRG", width: 4096, height: 4096),
	]

	static func named(_ n: some StringProtocol) -> RenditionSize? { all.first { $0.name == n } }

	var contentFeatures: String { "DLNA.ORG_PN=\(profile);DLNA.ORG_OP=01;DLNA.ORG_CI=1;DLNA.ORG_FLAGS=00D00000000000000000000000000000" }
	var protocolInfo: String { "http-get:*:image/jpeg:\(contentFeatures)" }

	/// Long side of an image of w×h scaled to fit the box, never upscaled.
	func longSide(_ w: Int, _ h: Int) -> Int {
		guard w > 0, h > 0 else { return max(width, height) }
		let (bw, bh) = h > w ? (min(width, height), max(width, height)) : (max(width, height), min(width, height))
		let scale = min(1, Double(bw) / Double(w), Double(bh) / Double(h))
		return max(1, Int((Double(max(w, h)) * scale).rounded()))
	}
}

/// JPEG thumbnails and TV-sized photos, generated on first request and cached on disk.
/// ImageIO decodes HEIC and applies the EXIF orientation; ffmpeg grabs video frames and embedded cover art.
final class Thumbnails: Sendable {
	static var defaultDir: URL { URL.cachesDirectory.appending(path: "\(AppPaths.bundleID)/thumbs", directoryHint: .isDirectory) }

	let dir: URL
	let ffmpeg: String?
	/// Large photos need a lot of memory to decode.
	private let slots = AsyncSemaphore(2)
	private let inFlight = Mutex<[String: Task<URL?, Never>]>([:])

	init(dir: URL = Thumbnails.defaultDir, ffmpeg: String? = Thumbnails.findFFmpeg()) {
		self.dir = dir
		self.ffmpeg = ffmpeg
	}

	static func findFFmpeg() -> String? {
		let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
		return (path.split(separator: ":").map { "\($0)/ffmpeg" } + ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"])
			.first { FileManager.default.isExecutableFile(atPath: $0) }
	}

	/// The original is good enough for the TV: a JPEG within 4096 px that needs no rotation.
	static func servesOriginal(_ o: CatalogObject) -> Bool {
		o.format?.mime == "image/jpeg" && (o.width ?? 0) > 0 && (o.width ?? 0) <= 4096 && (o.height ?? 0) <= 4096 && (o.orientation ?? 1) <= 1
	}

	/// File of the rendition; nil when the item has no picture.
	func get(_ o: CatalogObject, _ size: RenditionSize) async -> URL? {
		guard let path = o.path, let kind = o.format?.kind, let n = Int64(o.id.dropFirst()) else { return nil }
		if size.name == "lrg", Self.servesOriginal(o) { return URL(filePath: path) }
		// A changed file gets a new key and so a fresh rendition.
		let key = "\(n)-\(size.name)-\(Int64(o.modified?.timeIntervalSince1970 ?? 0))-\(o.size)"
		let dst = dir.appending(path: String(format: "%02x/", n % 256) + key + ".jpg")
		let fm = FileManager.default
		if fm.fileExists(atPath: dst.path) { return dst }
		if fm.fileExists(atPath: dst.path + ".fail") { return nil }

		let task = inFlight.withLock { tasks in
			if let t = tasks[key] { return t }
			let t = Task { () -> URL? in
				await slots.wait()
				defer { slots.signal() }
				try? FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
				purge(n, size: size.name)
				if await generate(path, kind, o, size, dst) { return dst }
				// Remembered so a broken file doesn't start a converter on every request.
				FileManager.default.createFile(atPath: dst.path + ".fail", contents: nil)
				return nil
			}
			tasks[key] = t
			return t
		}
		let url = await task.value
		_ = inFlight.withLock { $0.removeValue(forKey: key) }
		return url
	}

	private func generate(_ path: String, _ kind: MediaKind, _ o: CatalogObject, _ size: RenditionSize, _ dst: URL) async -> Bool {
		switch kind {
		case .image:
			return Self.encode(from: URL(filePath: path), size, to: dst)
		case .audio:
			if await frame(path, at: nil, size, to: dst) { return true }
			return AudioMeta.folderCover((path as NSString).deletingLastPathComponent).map { Self.encode(from: URL(filePath: $0), size, to: dst) } ?? false
		case .video:
			// A frame at 10 % skips intros and black opening frames.
			let at = o.durationMs.map { Double($0) / 10000 } ?? 30
			if await frame(path, at: at, size, to: dst) { return true }
			return await frame(path, at: 0, size, to: dst)
		}
	}

	/// A video frame, or for audio (at nil) the embedded cover.
	private func frame(_ path: String, at: Double?, _ size: RenditionSize, to dst: URL) async -> Bool {
		guard let ffmpeg else { return false }
		let tmp = dst.path + ".tmp.jpg"
		defer { try? FileManager.default.removeItem(atPath: tmp) }
		let seek = at.map { ["-ss", String(format: "%.1f", $0)] } ?? []
		let fit = "scale=w=\(size.width):h=\(size.height):force_original_aspect_ratio=decrease"
		do {
			_ = try await Prober.run(ffmpeg, ["-nostdin", "-v", "error"] + seek + ["-i", path, "-map", "0:v:0", "-frames:v", "1", "-vf", fit,
			                                                                     "-q:v", "4", "-f", "image2", "-y", tmp], timeout: 60)
		} catch {
			Log.library.debug("thumbnail of \(path, privacy: .public) failed: \(error, privacy: .public)")
			return false
		}
		guard ((try? FileManager.default.attributesOfItem(atPath: tmp)[.size] as? Int) ?? 0) > 0 else { return false }
		return rename(tmp, dst.path) == 0
	}

	/// Decodes any image ImageIO knows (HEIC included), rotates it upright, fits the box and writes a JPEG atomically.
	static func encode(from src: URL, _ size: RenditionSize, to dst: URL) -> Bool {
		guard let source = CGImageSourceCreateWithURL(src as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
		      let p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return false }
		var w = p[kCGImagePropertyPixelWidth] as? Int ?? 0, h = p[kCGImagePropertyPixelHeight] as? Int ?? 0
		if (p[kCGImagePropertyOrientation] as? Int ?? 1) >= 5 { swap(&w, &h) }
		let opts: [CFString: Any] = [
			kCGImageSourceCreateThumbnailFromImageAlways: true,
			kCGImageSourceCreateThumbnailWithTransform: true,
			kCGImageSourceThumbnailMaxPixelSize: size.longSide(w, h),
			kCGImageSourceShouldCacheImmediately: true,
		]
		guard let img = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) else { return false }
		let tmp = URL(filePath: dst.path + ".tmp")
		guard let out = CGImageDestinationCreateWithURL(tmp as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return false }
		CGImageDestinationAddImage(out, img, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
		guard CGImageDestinationFinalize(out) else { return false }
		return rename(tmp.path, dst.path) == 0
	}

	/// Older renditions of the same size (from before the file changed).
	private func purge(_ id: Int64, size: String) {
		let shard = dir.appending(path: String(format: "%02x", id % 256))
		let prefix = "\(id)-\(size)-"
		for name in (try? FileManager.default.contentsOfDirectory(atPath: shard.path)) ?? [] where name.hasPrefix(prefix) {
			try? FileManager.default.removeItem(at: shard.appending(path: name))
		}
	}
}

/// Limits concurrent work without blocking threads.
final class AsyncSemaphore: Sendable {
	private struct State {
		var free: Int
		var waiters: [CheckedContinuation<Void, Never>] = []
	}
	private let state: Mutex<State>

	init(_ n: Int) { state = Mutex(State(free: n)) }

	func wait() async {
		await withCheckedContinuation { cont in
			let ready = state.withLock { s in
				if s.free > 0 { s.free -= 1; return true }
				s.waiters.append(cont)
				return false
			}
			if ready { cont.resume() }
		}
	}

	func signal() {
		let next = state.withLock { s in
			if s.waiters.isEmpty { s.free += 1; return nil as CheckedContinuation<Void, Never>? }
			return s.waiters.removeFirst()
		}
		next?.resume()
	}
}
