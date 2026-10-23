import Foundation
import SQLite3

let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum StoreError: LocalizedError, Equatable {
    case open(String)
    case sql(String)
    case invalidBackup(String)
    case newerSchema(Int)

    public var errorDescription: String? {
        switch self {
        case .open(let m): return "Could not open the Workday database: \(m)"
        case .sql(let m): return "Database error: \(m)"
        case .invalidBackup(let m): return "The backup is not valid: \(m)"
        case .newerSchema(let v): return "This data was written by a newer version of Workday (schema \(v))."
        }
    }
}

public enum SQLValue {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
}

/// A single row cursor; valid only inside the query callback.
public struct SQLRow {
    let stmt: OpaquePointer

    public func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }
    public func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
    public func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
    public func text(_ i: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, i) else { return "" }
        return String(cString: c)
    }
    public func optionalDouble(_ i: Int32) -> Double? { isNull(i) ? nil : double(i) }
    public func optionalText(_ i: Int32) -> String? { isNull(i) ? nil : text(i) }
}

/// Minimal, dependency-free wrapper around the system SQLite library.
public final class SQLiteDatabase {
    public let path: String
    private(set) var handle: OpaquePointer?
    private var transactionDepth = 0

    public init(path: String, readOnly: Bool = false) throws {
        self.path = path
        var db: OpaquePointer?
        let flags = (readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)) | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "code \(rc)"
            if let db { sqlite3_close_v2(db) }
            throw StoreError.open(message)
        }
        handle = db
        sqlite3_busy_timeout(db, 5000)
    }

    deinit { close() }

    public func close() {
        if let handle { sqlite3_close_v2(handle) }
        handle = nil
    }

    var lastError: String {
        guard let handle else { return "database closed" }
        return String(cString: sqlite3_errmsg(handle))
    }

    public func execute(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &err) == SQLITE_OK else {
            let message = err.map { String(cString: $0) } ?? lastError
            sqlite3_free(err)
            throw StoreError.sql(message)
        }
    }

    private func prepare(_ sql: String, _ params: [SQLValue]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw StoreError.sql(lastError)
        }
        for (index, value) in params.enumerated() {
            let i = Int32(index + 1)
            switch value {
            case .null: sqlite3_bind_null(stmt, i)
            case .int(let v): sqlite3_bind_int64(stmt, i, v)
            case .double(let v): sqlite3_bind_double(stmt, i, v)
            case .text(let v): sqlite3_bind_text(stmt, i, v, -1, SQLITE_TRANSIENT)
            }
        }
        return stmt
    }

    /// Runs a statement that returns no rows.
    public func run(_ sql: String, _ params: [SQLValue] = []) throws {
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw StoreError.sql(lastError) }
    }

    public func query(_ sql: String, _ params: [SQLValue] = [], row: (SQLRow) throws -> Void) throws {
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                try row(SQLRow(stmt: stmt))
            } else if rc == SQLITE_DONE {
                break
            } else {
                throw StoreError.sql(lastError)
            }
        }
    }

    public var changes: Int { Int(sqlite3_changes(handle)) }

    /// Runs `body` atomically. Nested calls join the outer transaction.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        if transactionDepth > 0 {
            transactionDepth += 1
            defer { transactionDepth -= 1 }
            return try body()
        }
        try execute("BEGIN IMMEDIATE")
        transactionDepth = 1
        do {
            let result = try body()
            transactionDepth = 0
            try execute("COMMIT")
            return result
        } catch {
            transactionDepth = 0
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Copies the full contents of `source` into `destination` using SQLite's online backup API.
    /// Safe for live databases (never a raw file copy).
    static func copy(from source: SQLiteDatabase, to destination: SQLiteDatabase) throws {
        guard let backup = sqlite3_backup_init(destination.handle, "main", source.handle, "main") else {
            throw StoreError.sql(destination.lastError)
        }
        let rc = sqlite3_backup_step(backup, -1)
        sqlite3_backup_finish(backup)
        guard rc == SQLITE_DONE else {
            throw StoreError.sql("backup step failed (code \(rc)): \(destination.lastError)")
        }
    }
}
