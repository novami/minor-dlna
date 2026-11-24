import Foundation
import SQLite3

nonisolated struct SQLiteError: Error, CustomStringConvertible {
	let code: Int32
	let message: String
	var description: String { "SQLite \(code): \(message)" }
}

/// A value bound to a "?" placeholder; Optional binds NULL.
nonisolated protocol SQLBindable {
	func bind(_ stmt: OpaquePointer, _ i: Int32)
}

nonisolated private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

nonisolated extension Int: SQLBindable { func bind(_ s: OpaquePointer, _ i: Int32) { sqlite3_bind_int64(s, i, Int64(self)) } }
nonisolated extension Int64: SQLBindable { func bind(_ s: OpaquePointer, _ i: Int32) { sqlite3_bind_int64(s, i, self) } }
nonisolated extension Bool: SQLBindable { func bind(_ s: OpaquePointer, _ i: Int32) { sqlite3_bind_int64(s, i, self ? 1 : 0) } }
nonisolated extension Double: SQLBindable { func bind(_ s: OpaquePointer, _ i: Int32) { sqlite3_bind_double(s, i, self) } }
nonisolated extension String: SQLBindable { func bind(_ s: OpaquePointer, _ i: Int32) { sqlite3_bind_text(s, i, self, -1, transient) } }
nonisolated extension Optional: SQLBindable where Wrapped: SQLBindable {
	func bind(_ s: OpaquePointer, _ i: Int32) {
		if let v = self { v.bind(s, i) } else { sqlite3_bind_null(s, i) }
	}
}

/// Column access of the current result row.
nonisolated struct Row {
	fileprivate let stmt: OpaquePointer

	func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(stmt, i)) }
	func int64(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
	func optInt(_ i: Int32) -> Int? { isNull(i) ? nil : int(i) }
	func bool(_ i: Int32) -> Bool { sqlite3_column_int64(stmt, i) != 0 }
	func text(_ i: Int32) -> String { sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? "" }
	func optText(_ i: Int32) -> String? { isNull(i) ? nil : text(i) }
	func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }
}

/// One SQLite connection; calls are serialised, transactions may nest calls on the same connection.
nonisolated final class Database: @unchecked Sendable {
	private var db: OpaquePointer?
	private let lock = NSRecursiveLock()

	init(path: String, readOnly: Bool = false) throws {
		let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) | SQLITE_OPEN_NOMUTEX
		let rc = sqlite3_open_v2(path, &db, flags, nil)
		guard rc == SQLITE_OK else {
			let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
			sqlite3_close(db)
			throw SQLiteError(code: rc, message: msg)
		}
		sqlite3_busy_timeout(db, 5000)
		try execute("PRAGMA foreign_keys = ON")
	}

	deinit { sqlite3_close_v2(db) }

	/// Runs one or more statements without parameters.
	func execute(_ sql: String) throws {
		try locked {
			var err: UnsafeMutablePointer<CChar>?
			let rc = sqlite3_exec(db, sql, nil, nil, &err)
			if rc != SQLITE_OK {
				let msg = err.map { String(cString: $0) } ?? ""
				sqlite3_free(err)
				throw SQLiteError(code: rc, message: msg)
			}
		}
	}

	@discardableResult
	func run(_ sql: String, _ args: any SQLBindable...) throws -> Int { try run(sql, args) }

	@discardableResult
	func run(_ sql: String, _ args: [any SQLBindable]) throws -> Int {
		try locked {
			try withStatement(sql, args) { stmt in
				while try step(stmt) {}
				return Int(sqlite3_changes(db))
			}
		}
	}

	func query<T>(_ sql: String, _ args: any SQLBindable..., map: (Row) throws -> T) throws -> [T] {
		try query(sql, args, map: map)
	}

	func query<T>(_ sql: String, _ args: [any SQLBindable], map: (Row) throws -> T) throws -> [T] {
		try locked {
			try withStatement(sql, args) { stmt in
				var out: [T] = []
				while try step(stmt) { out.append(try map(Row(stmt: stmt))) }
				return out
			}
		}
	}

	func one<T>(_ sql: String, _ args: any SQLBindable..., map: (Row) throws -> T) throws -> T? {
		try query(sql, args, map: map).first
	}

	func transaction<T>(_ body: () throws -> T) throws -> T {
		try locked {
			try execute("BEGIN IMMEDIATE")
			do {
				let v = try body()
				try execute("COMMIT")
				return v
			} catch {
				try? execute("ROLLBACK")
				throw error
			}
		}
	}

	private func locked<T>(_ body: () throws -> T) rethrows -> T {
		lock.lock()
		defer { lock.unlock() }
		return try body()
	}

	private func withStatement<T>(_ sql: String, _ args: [any SQLBindable], _ body: (OpaquePointer) throws -> T) throws -> T {
		var stmt: OpaquePointer?
		let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
		guard rc == SQLITE_OK, let stmt else { throw error(rc) }
		defer { sqlite3_finalize(stmt) }
		for (i, a) in args.enumerated() { a.bind(stmt, Int32(i + 1)) }
		return try body(stmt)
	}

	private func step(_ stmt: OpaquePointer) throws -> Bool {
		switch sqlite3_step(stmt) {
		case SQLITE_ROW: return true
		case SQLITE_DONE: return false
		case let rc: throw error(rc)
		}
	}

	private func error(_ rc: Int32) -> SQLiteError {
		SQLiteError(code: rc, message: String(cString: sqlite3_errmsg(db)))
	}
}
