import Foundation

/// A TV (UPnP MediaRenderer) that can play our streams.
public struct Renderer: Sendable, Equatable, Identifiable {
	public var udn: String
	public var name: String
	public var maker: String
	public var model: String
	/// Device description URL.
	var location: String
	public var ip: String
	/// For Wake-on-LAN; empty until read from the ARP table while the TV was on.
	public var mac: String
	/// Answered the last search.
	public var online = false
	var avTransport: String?
	var renderingControl: String?

	public var id: String { udn }
}

/// A message for the user (Czech).
public struct TVError: Error, Equatable, CustomStringConvertible {
	public let description: String
	init(_ message: String) { description = message }
}

/// A UPnP fault returned by the TV.
struct UPnPFault: Error, CustomStringConvertible {
	let code: Int
	let message: String
	var description: String { "UPnP \(code): \(message)" }
}

enum UPnPClient {
	static let rendererType = "urn:schemas-upnp-org:device:MediaRenderer:"
	static let avTransport = "urn:schemas-upnp-org:service:AVTransport:1"
	static let renderingControl = "urn:schemas-upnp-org:service:RenderingControl:1"
	/// LG answers these only once playback starts or the seek lands, which takes well over 10 s for a big file.
	static let slowActions: Set = ["SetAVTransportURI", "Play", "Seek"]

	static func describe(_ location: String) async throws -> Renderer {
		guard let url = URL(string: location) else { throw TVError("Neplatná adresa televize.") }
		let (data, res) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 5))
		guard (res as? HTTPURLResponse)?.statusCode == 200 else { throw TVError("Televize nevrátila popis zařízení.") }
		guard let r = parseDescription(data, location: url) else { throw TVError("Zařízení není přehrávač s AVTransport.") }
		return r
	}

	/// The MediaRenderer in a device description, with absolute control URLs.
	static func parseDescription(_ data: Data, location: URL) -> Renderer? {
		let reader = DescriptionReader()
		let parser = XMLParser(data: data)
		parser.shouldProcessNamespaces = true
		parser.delegate = reader
		guard parser.parse() else { return nil }
		let base = reader.urlBase.flatMap { URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? location
		guard let d = reader.devices.first(where: { $0.fields["deviceType"]?.hasPrefix(rendererType) == true }),
		      let udn = d.fields["UDN"], !udn.isEmpty else { return nil }
		func control(_ prefix: String) -> String? {
			d.services.first { $0["serviceType"]?.hasPrefix(prefix) == true }
				.flatMap { $0["controlURL"] }
				.flatMap { URL(string: $0.trimmingCharacters(in: .whitespaces), relativeTo: base)?.absoluteString }
		}
		guard let avt = control("urn:schemas-upnp-org:service:AVTransport:") else { return nil }
		let field = { (k: String) in d.fields[k]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
		return Renderer(udn: udn, name: field("friendlyName"), maker: field("manufacturer"), model: field("modelName"),
		                location: location.absoluteString, ip: base.host() ?? location.host() ?? "", mac: "",
		                online: true, avTransport: avt, renderingControl: control("urn:schemas-upnp-org:service:RenderingControl:"))
	}

	/// Invokes action and returns the output arguments.
	static func call(_ controlURL: String, _ service: String, _ action: String, _ args: KeyValuePairs<String, String>) async throws -> [String: String] {
		guard let url = URL(string: controlURL) else { throw TVError("Neplatná adresa televize.") }
		var b = #"<?xml version="1.0" encoding="utf-8"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>"#
		b += #"<u:\#(action) xmlns:u="\#(service)">"#
		for (k, v) in args { b += "<\(k)>\(v.xmlEscaped)</\(k)>" }
		b += "</u:\(action)></s:Body></s:Envelope>"
		var req = URLRequest(url: url, timeoutInterval: slowActions.contains(action) ? 60 : 5)
		req.httpMethod = "POST"
		req.httpBody = Data(b.utf8)
		req.setValue(#"text/xml; charset="utf-8""#, forHTTPHeaderField: "Content-Type")
		req.setValue(#""\#(service)#\#(action)""#, forHTTPHeaderField: "SOAPAction")
		let (data, res) = try await URLSession.shared.data(for: req)
		let status = (res as? HTTPURLResponse)?.statusCode ?? 0
		let (out, fault) = parseResponse(data)
		if let fault { throw fault }
		guard status == 200 else { throw TVError("\(action): HTTP \(status)") }
		return out
	}

	/// Leaf elements of the body: output arguments, or errorCode/errorDescription of a fault.
	static func parseResponse(_ data: Data) -> ([String: String], UPnPFault?) {
		let reader = LeafReader()
		let parser = XMLParser(data: data)
		parser.shouldProcessNamespaces = true
		parser.delegate = reader
		_ = parser.parse()
		guard reader.fault else { return (reader.leaves, nil) }
		let desc = reader.leaves["errorDescription"] ?? reader.leaves["faultstring"] ?? ""
		return ([:], UPnPFault(code: Int(reader.leaves["errorCode"] ?? "") ?? 0, message: desc))
	}

	/// H:MM:SS[.fff] in milliseconds; nil for NOT_IMPLEMENTED and the like.
	static func parseTime(_ s: String) -> Int? {
		let parts = s.trimmingCharacters(in: .whitespaces).split(separator: ".", maxSplits: 1)
		guard let hms = parts.first?.split(separator: ":", omittingEmptySubsequences: false), hms.count == 3 else { return nil }
		var ms = 0
		for p in hms {
			guard let n = Int(p), n >= 0 else { return nil }
			ms = ms * 60 + n
		}
		ms *= 1000
		if parts.count == 2, let f = Double("0." + parts[1]) { ms += Int(f * 1000) }
		return ms
	}

	static func formatTime(_ ms: Int) -> String {
		let s = ms / 1000
		return String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
	}

	/// Stream URIs compared by path: TVs may echo the host or escaping differently.
	static func sameURI(_ a: String, _ b: String) -> Bool {
		guard let ua = URL(string: a), let ub = URL(string: b) else { return a == b }
		return ua.path() == ub.path()
	}
}

private final class DescriptionReader: NSObject, XMLParserDelegate {
	struct Device {
		var fields: [String: String] = [:]
		var services: [[String: String]] = []
	}

	var urlBase: String?
	var devices: [Device] = []
	private var open: [Device] = []
	private var service: [String: String]?
	private var text = ""

	func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
	            attributes: [String: String] = [:]) {
		if name == "device" { open.append(Device()) }
		if name == "service" { service = [:] }
		text = ""
	}

	func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

	func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
		switch name {
		case "device":
			if let d = open.popLast() { devices.append(d) }
		case "service":
			if let s = service, !open.isEmpty { open[open.count - 1].services.append(s) }
			service = nil
		case "URLBase":
			urlBase = text
		default:
			if service != nil {
				service?[name] = text
			} else if !open.isEmpty, open[open.count - 1].fields[name] == nil {
				open[open.count - 1].fields[name] = text
			}
		}
		text = ""
	}
}

private final class LeafReader: NSObject, XMLParserDelegate {
	var leaves: [String: String] = [:]
	var fault = false
	private var current: String?
	private var text = ""

	func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
	            attributes: [String: String] = [:]) {
		if name == "Fault" { fault = true }
		current = name
		text = ""
	}

	func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

	func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
		if current == name { leaves[name] = text }
		current = nil
	}
}
