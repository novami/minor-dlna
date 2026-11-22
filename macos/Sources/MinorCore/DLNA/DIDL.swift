import Foundation

enum DIDL {
	static let header = #"<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" "#
		+ #"xmlns:dc="http://purl.org/dc/elements/1.1/" "#
		+ #"xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" "#
		+ #"xmlns:dlna="urn:schemas-dlna-org:metadata-1-0/">"#

	/// baseURL is "http://host:port" as the client sees the server.
	static func render(_ objects: [CatalogObject], baseURL: String) -> String {
		var b = header
		for o in objects {
			if o.isContainer {
				b += #"<container id="\#(o.id.xmlEscaped)" parentID="\#(o.parentID.xmlEscaped)" restricted="1" searchable="0""#
				if let n = o.childCount { b += #" childCount="\#(n)""# }
				b += "><dc:title>\(o.title.xmlEscaped)</dc:title><upnp:class>\(o.upnpClass ?? "object.container.storageFolder")</upnp:class>"
				if let a = o.artist { b += "<upnp:artist>\(a.xmlEscaped)</upnp:artist>" }
				b += "</container>"
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
				b += #"<res protocolInfo="\#(f.protocolInfo.xmlEscaped)""#
				if o.size > 0 { b += #" size="\#(o.size)""# }
				if let d = o.durationMs, d > 0 { b += #" duration="\#(duration(d))""# }
				if let w = o.width, let h = o.height, w > 0, h > 0 { b += #" resolution="\#(w)x\#(h)""# }
				b += ">\((baseURL + mediaPath(o)).xmlEscaped)</res></item>"
			}
		}
		return b + "</DIDL-Lite>"
	}

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
