import Foundation

/// One entry of the ContentDirectory tree.
struct CatalogObject: Sendable, Equatable {
	var id: String
	var parentID: String
	var title: String
	var isContainer: Bool
	var path: String?
	var format: MediaFormat?
	var size: Int64 = 0
	var modified: Date?
}

/// Browses the configured library folders directly on disk (no database yet).
///
/// IDs: "0" root, "L<uuid>" library, "F<base64url path>" folder or file. Media URLs use the same token,
/// so the server only needs the path to answer and never serves anything outside the library roots.
struct FolderCatalog: Sendable {
	let libraries: [Library]

	func metadata(_ id: String) throws(UPnPError) -> CatalogObject {
		if id == "0" {
			return CatalogObject(id: "0", parentID: "-1", title: "MinorDLNA", isContainer: true)
		}
		if let lib = library(id) {
			return CatalogObject(id: id, parentID: "0", title: lib.name, isContainer: true)
		}
		guard let path = Self.path(fromToken: id.dropFirst()), id.first == "F", let lib = owner(of: path),
		      let obj = object(at: path, in: lib) else { throw .noSuchObject }
		return obj
	}

	func children(_ id: String, start: Int, count: Int) throws(UPnPError) -> (objects: [CatalogObject], total: Int) {
		let all: [CatalogObject]
		if id == "0" {
			all = libraries.map { CatalogObject(id: "L\($0.id.uuidString)", parentID: "0", title: $0.name, isContainer: true) }
		} else if let lib = library(id) {
			all = sorted(lib.paths.flatMap { list(dir: $0, in: lib) })
		} else if id.first == "F", let path = Self.path(fromToken: id.dropFirst()), let lib = owner(of: path) {
			all = sorted(list(dir: path, in: lib))
		} else {
			throw .noSuchObject
		}
		let from = min(start, all.count)
		let to = count == 0 ? all.count : min(from + count, all.count)
		return (Array(all[from..<to]), all.count)
	}

	/// Resolves a media URL token to a file inside a library root.
	func media(token: Substring) -> CatalogObject? {
		guard let path = Self.path(fromToken: token), let lib = owner(of: path),
		      let obj = object(at: path, in: lib), !obj.isContainer else { return nil }
		return obj
	}

	// MARK: -

	private func library(_ id: String) -> Library? {
		guard id.first == "L", let uuid = UUID(uuidString: String(id.dropFirst())) else { return nil }
		return libraries.first { $0.id == uuid }
	}

	/// The library whose root contains path; tokens are canonical, so a plain prefix check is enough.
	private func owner(of path: String) -> Library? {
		libraries.first { lib in lib.paths.contains { root in path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/") } }
	}

	private func parentID(of path: String, in lib: Library) -> String {
		let parent = (path as NSString).deletingLastPathComponent
		return lib.paths.contains(parent) ? "L\(lib.id.uuidString)" : "F" + Self.token(for: parent)
	}

	private func object(at path: String, in lib: Library) -> CatalogObject? {
		guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
		let isDir = attrs[.type] as? FileAttributeType == .typeDirectory
		let name = (path as NSString).lastPathComponent
		if isDir {
			return CatalogObject(id: "F" + Self.token(for: path), parentID: parentID(of: path, in: lib), title: name,
			                     isContainer: true, path: path)
		}
		guard let format = MediaFormat.lookup(path), lib.type.accepts(format.kind) else { return nil }
		return CatalogObject(id: "F" + Self.token(for: path), parentID: parentID(of: path, in: lib),
		                     title: (name as NSString).deletingPathExtension, isContainer: false, path: path, format: format,
		                     size: (attrs[.size] as? NSNumber)?.int64Value ?? 0, modified: attrs[.modificationDate] as? Date)
	}

	private func list(dir: String, in lib: Library) -> [CatalogObject] {
		guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
		return names.lazy.filter { !$0.hasPrefix(".") }.compactMap { object(at: (dir as NSString).appendingPathComponent($0), in: lib) }
	}

	private func sorted(_ objs: [CatalogObject]) -> [CatalogObject] {
		objs.sorted { a, b in
			if a.isContainer != b.isContainer { return a.isContainer }
			return a.title.localizedStandardCompare(b.title) == .orderedAscending
		}
	}

	static func token(for path: String) -> String {
		Data(path.utf8).base64EncodedString()
			.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
			.replacingOccurrences(of: "=", with: "")
	}

	static func path(fromToken token: Substring) -> String? {
		var b64 = token.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
		b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
		guard let data = Data(base64Encoded: b64), let path = String(data: data, encoding: .utf8), path.hasPrefix("/") else { return nil }
		// Only canonical absolute paths, so ".." cannot escape a root. (URL.standardized would also turn /private/tmp into /tmp.)
		let parts = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
		return parts.contains { $0.isEmpty || $0 == "." || $0 == ".." } ? nil : path
	}
}

extension LibraryType {
	func accepts(_ kind: MediaKind) -> Bool {
		switch self {
		case .movies, .shows, .videos: kind == .video
		case .photos: kind == .image
		case .music: kind == .audio
		}
	}
}
