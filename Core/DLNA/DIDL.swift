import Foundation

nonisolated enum DIDL {
	static let header = #"<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" "#
		+ #"xmlns:dc="http://purl.org/dc/elements/1.1/" "#
		+ #"xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" "#
		+ #"xmlns:dlna="urn:schemas-dlna-org:metadata-1-0/" "#
		+ #"xmlns:sec="http://www.sec.co.kr/" "#
		+ #"xmlns:pv="http://www.pv.com/pvns/">"#

	/// baseURL is "http://host:port" as the client sees the server; profile nil means no transcoding.
	static func render(_ objects: [CatalogObject], baseURL: String, profile: Profile? = nil) -> String {
		var b = header
		for o in objects {
			if o.isContainer {
				b += #"<container id="\#(o.id.xmlEscaped)" parentID="\#(o.parentID.xmlEscaped)" restricted="1" searchable="0""#
				if let n = o.childCount { b += #" childCount="\#(n)""# }
				b += "><dc:title>\(o.title.xmlEscaped)</dc:title><upnp:class>\(o.upnpClass ?? "object.container.storageFolder")</upnp:class>"
				if let a = o.artist { b += "<upnp:artist>\(a.xmlEscaped)</upnp:artist>" }
				if let g = o.genre { b += "<upnp:genre>\(g.xmlEscaped)</upnp:genre>" }
				b += details(o) + art(o, baseURL) + "</container>"
			} else if let f = o.format {
				b += #"<item id="\#(o.id.xmlEscaped)" parentID="\#(o.parentID.xmlEscaped)" restricted="1">"#
				b += "<dc:title>\(o.title.xmlEscaped)</dc:title><upnp:class>\(itemClass(f.kind))</upnp:class>"
				if f.kind == .image, let t = o.taken {
					b += "<dc:date>\(localDate.string(from: t))</dc:date>"
				} else if let y = o.year {
					b += "<dc:date>\(y)-01-01</dc:date>"
				} else if let m = o.modified {
					b += "<dc:date>\(dateFormat.string(from: m))</dc:date>"
				}
				if f.kind == .audio {
					if let a = o.artist { b += "<upnp:artist>\(a.xmlEscaped)</upnp:artist><dc:creator>\(a.xmlEscaped)</dc:creator>" }
					if let a = o.album { b += "<upnp:album>\(a.xmlEscaped)</upnp:album>" }
					if let t = o.track, t > 0 { b += "<upnp:originalTrackNumber>\(t)</upnp:originalTrackNumber>" }
				}
				if let g = o.genre { b += "<upnp:genre>\(g.xmlEscaped)</upnp:genre>" }
				if f.kind == .video, o.positionMs > 0 || o.watched {
					// UPnP AV bookmark and play count; whether LG draws a progress bar from them is unverified.
					if o.positionMs > 0 { b += "<upnp:lastPlaybackPosition>\(duration(o.positionMs))</upnp:lastPlaybackPosition>" }
					b += "<upnp:playbackCount>\(o.watched ? 1 : 0)</upnp:playbackCount>"
				}
				b += details(o) + art(o, baseURL)
				let subs = o.subtitle != nil ? Int64(o.id.dropFirst()).map { baseURL + Subtitles.path(item: $0) } : nil
				if let subs { b += #"<sec:CaptionInfoEx sec:type="srt">\#(subs.xmlEscaped)</sec:CaptionInfoEx>"# }
				if f.kind == .image {
					b += photoRes(o, baseURL)
				} else {
					// Sony, Philips and some Android players read subtitles from pv: attributes of the media resource.
					let attrs = subs.map { #" pv:subtitleFileType="SRT" pv:subtitleFileUri="\#($0.xmlEscaped)""# } ?? ""
					// Only the converted stream: offering the original too lets the TV pick a format it can't play.
					let s = stream(o, f, profile)
					b += res(s.protocolInfo, s.size, o.durationMs, o.width, o.height, baseURL + s.path, attrs)
				}
				if let subs { b += res("http-get:*:text/srt:*", 0, nil, nil, nil, subs) }
				b += "</item>"
			}
		}
		return b + "</DIDL-Lite>"
	}

	/// Overview and people of a matched movie or show.
	private static func details(_ o: CatalogObject) -> String {
		var b = ""
		if let d = o.overview { b += "<dc:description>\(d.xmlEscaped)</dc:description>" }
		if let d = o.director { b += "<upnp:director>\(d.xmlEscaped)</upnp:director>" }
		for a in o.cast.prefix(5) { b += "<upnp:actor>\(a.xmlEscaped)</upnp:actor>" }
		return b
	}

	static func posterPath(_ meta: Int64, _ size: String) -> String { "/poster/\(meta)/\(size).jpg" }

	private static func art(_ o: CatalogObject, _ baseURL: String) -> String {
		if let p = o.poster {
			return #"<upnp:albumArtURI dlna:profileID="JPEG_TN">\#((baseURL + posterPath(p, "tn")).xmlEscaped)</upnp:albumArtURI>"#
		}
		guard let n = o.artItem, o.format?.kind != .image else { return "" }
		return #"<upnp:albumArtURI dlna:profileID="JPEG_TN">\#((baseURL + thumbPath(n, "tn")).xmlEscaped)</upnp:albumArtURI>"#
	}

	/// A TV-sized rendition first (LG picks the first resource), then the original and smaller sizes. HEIC only as JPEG.
	private static func photoRes(_ o: CatalogObject, _ baseURL: String) -> String {
		guard let n = Int64(o.id.dropFirst()), let f = o.format else { return "" }
		var b = ""
		let derived = { (size: String) in
			// swiftlint:disable:next force_unwrapping
			let s = RenditionSize.named(size)!
			return res(s.protocolInfo, 0, nil, nil, nil, baseURL + thumbPath(n, size))
		}
		if Thumbnails.servesOriginal(o) {
			// swiftlint:disable:next force_unwrapping
			b += res(RenditionSize.named("lrg")!.protocolInfo.replacingOccurrences(of: "CI=1", with: "CI=0"), o.size, nil, o.width, o.height,
			         baseURL + mediaPath(o))
		} else {
			b += derived("lrg")
			if f.mime != "image/heic", f.mime != "image/heif" {
				b += res(f.protocolInfo, o.size, nil, o.width, o.height, baseURL + mediaPath(o))
			}
		}
		return b + derived("sm") + derived("tn")
	}

	private static func res(_ protocolInfo: String, _ size: Int64, _ durationMs: Int?, _ w: Int?, _ h: Int?, _ url: String,
	                        _ attrs: String = "") -> String {
		var b = #"<res protocolInfo="\#(protocolInfo.xmlEscaped)""# + attrs
		if size > 0 { b += #" size="\#(size)""# }
		if let d = durationMs, d > 0 { b += #" duration="\#(duration(d))""# }
		if let w, let h, w > 0, h > 0 { b += #" resolution="\#(w)x\#(h)""# }
		return b + ">\(url.xmlEscaped)</res>"
	}

	/// The URL path an item plays from for this profile (nil: no transcoding), with its size (0 when converted).
	static func stream(_ o: CatalogObject, _ f: MediaFormat, _ profile: Profile?) -> (path: String, protocolInfo: String, size: Int64) {
		let plan = profile.map { Plan.decide($0, o) } ?? .direct
		if !plan.isDirect, let n = Int64(o.id.dropFirst()) { return (plan.path(item: n), plan.protocolInfo, 0) }
		return (mediaPath(o), f.protocolInfo, o.size)
	}

	static func thumbPath(_ item: Int64, _ size: String) -> String { "/thumb/\(item)/\(size).jpg" }

	/// /media/<id>.<ext>; the extension helps clients that guess the type from the URL.
	static func mediaPath(_ o: CatalogObject) -> String {
		let ext = ((o.path ?? "") as NSString).pathExtension.lowercased()
		return "/media/\(o.id.dropFirst())" + (ext.isEmpty ? "" : ".\(ext)")
	}

	/// H:MM:SS.mmm
	static func duration(_ ms: Int) -> String {
		String(format: "%d:%02d:%02d.%03d", ms / 3_600_000, ms / 60000 % 60, ms / 1000 % 60, ms % 1000)
	}

	private static func itemClass(_ k: MediaKind) -> String {
		switch k {
		case .video: "object.item.videoItem"
		case .image: "object.item.imageItem.photo"
		case .audio: "object.item.audioItem.musicTrack"
		}
	}

	private static let dateFormat: DateFormatter = {
		let f = DateFormatter()
		f.locale = Locale(identifier: "en_US_POSIX")
		f.timeZone = TimeZone(identifier: "UTC")
		f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
		return f
	}()

	/// Photo capture time as the camera clock showed it.
	private static let localDate: DateFormatter = {
		let f = DateFormatter()
		f.locale = Locale(identifier: "en_US_POSIX")
		f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
		return f
	}()
}
