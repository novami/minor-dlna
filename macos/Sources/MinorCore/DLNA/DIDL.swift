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
				b += #"<container id="\#(o.id.xmlEscaped)" parentID="\#(o.parentID.xmlEscaped)" restricted="1" searchable="0">"#
				b += "<dc:title>\(o.title.xmlEscaped)</dc:title><upnp:class>object.container.storageFolder</upnp:class></container>"
			} else if let f = o.format {
				b += #"<item id="\#(o.id.xmlEscaped)" parentID="\#(o.parentID.xmlEscaped)" restricted="1">"#
				b += "<dc:title>\(o.title.xmlEscaped)</dc:title><upnp:class>\(itemClass(f.kind))</upnp:class>"
				if let m = o.modified { b += "<dc:date>\(dateFormat.string(from: m))</dc:date>" }
				b += #"<res protocolInfo="\#(f.protocolInfo.xmlEscaped)""#
				if o.size > 0 { b += #" size="\#(o.size)""# }
				b += ">\((baseURL + mediaPath(o)).xmlEscaped)</res></item>"
			}
		}
		return b + "</DIDL-Lite>"
	}

	/// /media/<token>.<ext>; the extension helps clients that guess the type from the URL.
	static func mediaPath(_ o: CatalogObject) -> String {
		let ext = ((o.path ?? "") as NSString).pathExtension.lowercased()
		return "/media/\(o.id.dropFirst())" + (ext.isEmpty ? "" : ".\(ext)")
	}

	private static func itemClass(_ k: MediaKind) -> String {
		switch k {
		case .video: "object.item.videoItem"
		case .image: "object.item.imageItem.photo"
		case .audio: "object.item.audioItem.musicTrack"
		}
	}

	// DateFormatter is thread-safe since macOS 10.9.
	nonisolated(unsafe) private static let dateFormat: DateFormatter = {
		let f = DateFormatter()
		f.locale = Locale(identifier: "en_US_POSIX")
		f.timeZone = TimeZone(identifier: "UTC")
		f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
		return f
	}()
}
