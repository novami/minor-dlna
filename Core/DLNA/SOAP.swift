import Foundation

nonisolated struct UPnPError: Error, Equatable {
	let code: Int
	let description: String

	static let invalidAction = UPnPError(code: 401, description: "Invalid Action")
	static let invalidArgs = UPnPError(code: 402, description: "Invalid Args")
	static let actionFailed = UPnPError(code: 501, description: "Action Failed")
	static let noSuchObject = UPnPError(code: 701, description: "No such object")
}

nonisolated enum SOAP {
	struct Call: Equatable {
		var action: String
		var args: [String: String]
	}

	/// Reads the action (first element inside Body) and its arguments. The SOAPAction header wins when present.
	static func parse(_ data: Data, soapAction: String?) -> Call? {
		let reader = EnvelopeReader()
		let parser = XMLParser(data: data)
		parser.shouldProcessNamespaces = true
		parser.delegate = reader
		guard parser.parse(), var action = reader.action else { return nil }
		if let sa = soapAction?.trimmingCharacters(in: CharacterSet(charactersIn: "\"")),
		   let hash = sa.lastIndex(of: "#") {
			action = String(sa[sa.index(after: hash)...])
		}
		return Call(action: action, args: reader.args)
	}

	static func response(action: String, serviceType: String, args: KeyValuePairs<String, String>) -> String {
		var b = #"<?xml version="1.0" encoding="utf-8"?>"#
		b += #"<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>"#
		b += #"<u:\#(action)Response xmlns:u="\#(serviceType)">"#
		for (name, value) in args { b += "<\(name)>\(value.xmlEscaped)</\(name)>" }
		b += "</u:\(action)Response></s:Body></s:Envelope>"
		return b
	}

	static func fault(_ e: UPnPError) -> String {
		#"<?xml version="1.0" encoding="utf-8"?>"#
			+ #"<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>"#
			+ "<s:Fault><faultcode>s:Client</faultcode><faultstring>UPnPError</faultstring><detail>"
			+ #"<UPnPError xmlns="urn:schemas-upnp-org:control-1-0"><errorCode>\#(e.code)</errorCode><errorDescription>\#(e.description.xmlEscaped)</errorDescription></UPnPError>"#
			+ "</detail></s:Fault></s:Body></s:Envelope>"
	}
}

nonisolated private final class EnvelopeReader: NSObject, XMLParserDelegate {
	var action: String?
	var args: [String: String] = [:]
	private var path: [String] = []
	private var text = ""

	func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
	            attributes: [String: String] = [:]) {
		// Envelope > Body > Action > Argument
		if path.count == 2, path[1] == "Body", action == nil { action = name }
		path.append(name)
		text = ""
	}

	func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

	func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
		if path.count == 4, path[1] == "Body" { args[name] = text }
		path.removeLast()
		text = ""
	}
}
