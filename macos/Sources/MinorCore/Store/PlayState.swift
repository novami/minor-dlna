import Foundation

extension Store {
	/// Played this far counts as watched and the saved position is cleared.
	static let watchedRatio = 0.9

	/// Records how far the file was played; durationMs 0 keeps the known duration.
	func savePosition(path: String, positionMs: Int, durationMs: Int) throws {
		let watched = durationMs > 0 && Double(positionMs) >= Self.watchedRatio * Double(durationMs)
		try writer.run("""
			INSERT INTO play_state (path, position_ms, duration_ms, watched, updated_at) VALUES (?, ?, ?, ?, ?)
			ON CONFLICT (path) DO UPDATE SET position_ms = excluded.position_ms,
				duration_ms = CASE WHEN excluded.duration_ms > 0 THEN excluded.duration_ms ELSE play_state.duration_ms END,
				watched = MAX(watched, excluded.watched), updated_at = excluded.updated_at
			""", path, watched ? 0 : max(positionMs, 0), durationMs, watched, Int64(Date().timeIntervalSince1970))
	}

	/// TVs seen so far, most recent first.
	func renderers() throws -> [Renderer] {
		try reader.query("SELECT udn, name, maker, model, location, ip, mac FROM renderer ORDER BY seen_at DESC") {
			Renderer(udn: $0.text(0), name: $0.text(1), maker: $0.text(2), model: $0.text(3), location: $0.text(4), ip: $0.text(5), mac: $0.text(6))
		}
	}

	/// Remembers a TV; an empty MAC keeps the known one (the ARP entry may have expired).
	func saveRenderer(_ r: Renderer) throws {
		try writer.run("""
			INSERT INTO renderer (udn, name, maker, model, location, ip, mac, seen_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
			ON CONFLICT (udn) DO UPDATE SET name = excluded.name, maker = excluded.maker, model = excluded.model,
				location = excluded.location, ip = excluded.ip,
				mac = CASE WHEN excluded.mac = '' THEN renderer.mac ELSE excluded.mac END, seen_at = excluded.seen_at
			""", r.udn, r.name, r.maker, r.model, r.location, r.ip, r.mac, Int64(Date().timeIntervalSince1970))
	}
}
