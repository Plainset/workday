import Foundation

/// Durable local storage for sessions, the audit log, settings and notification bookkeeping.
///
/// Uses SQLite in WAL mode with `synchronous=FULL`; every mutation runs in a transaction and
/// bumps `data_revision`, which drives the "back up daily when data changes" policy.
public final class WorkStore {
    public static let schemaVersion = 1

    public let db: SQLiteDatabase
    public var path: String { db.path }

    public init(path: String) throws {
        db = try SQLiteDatabase(path: path)
        try db.execute("PRAGMA journal_mode=WAL")
        try db.execute("PRAGMA synchronous=FULL")
        try db.execute("PRAGMA foreign_keys=ON")
        try migrate()
    }

    /// Creates/upgrades the schema. Refuses to open data from a newer schema.
    public func migrate() throws {
        try db.execute("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        let version = Int(meta("schema_version") ?? "0") ?? 0
        if version > Self.schemaVersion { throw StoreError.newerSchema(version) }
        if version < 1 {
            try db.transaction {
                try db.execute("""
                CREATE TABLE IF NOT EXISTS sessions (
                    id TEXT PRIMARY KEY,
                    start REAL NOT NULL,
                    end REAL,
                    state TEXT NOT NULL CHECK (state IN ('active','closed','interrupted')),
                    checkpoint REAL NOT NULL,
                    checkpoint_kind TEXT NOT NULL,
                    detected_at REAL,
                    tz TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    CHECK (end IS NULL OR end > start)
                );
                CREATE INDEX IF NOT EXISTS sessions_start ON sessions(start);
                CREATE TABLE IF NOT EXISTS events (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    at REAL NOT NULL,
                    kind TEXT NOT NULL,
                    session_id TEXT,
                    detail TEXT NOT NULL DEFAULT ''
                );
                CREATE TABLE IF NOT EXISTS notifications_sent (
                    day TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    sent_at REAL NOT NULL,
                    PRIMARY KEY (day, kind)
                );
                CREATE TABLE IF NOT EXISTS settings (
                    id INTEGER PRIMARY KEY CHECK (id = 1),
                    json TEXT NOT NULL
                );
                """)
                try setMeta("schema_version", "1")
                if meta("data_revision") == nil { try setMeta("data_revision", "0") }
            }
        }
    }

    // MARK: Meta

    public func meta(_ key: String) -> String? {
        var value: String?
        try? db.query("SELECT value FROM meta WHERE key = ?", [.text(key)]) { value = $0.text(0) }
        return value
    }

    public func setMeta(_ key: String, _ value: String) throws {
        try db.run("INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                   [.text(key), .text(value)])
    }

    public var dataRevision: Int { Int(meta("data_revision") ?? "0") ?? 0 }

    func bumpRevision() throws {
        try db.run("UPDATE meta SET value = CAST(value AS INTEGER) + 1 WHERE key = 'data_revision'")
    }

    // MARK: Sessions

    public func loadSessions() throws -> [WorkSession] {
        var result: [WorkSession] = []
        try db.query("""
            SELECT id, start, end, state, checkpoint, checkpoint_kind, detected_at, tz, created_at, updated_at
            FROM sessions ORDER BY start
            """) { row in
            guard let id = UUID(uuidString: row.text(0)) else { return }
            result.append(WorkSession(
                id: id,
                start: Date(timeIntervalSinceReferenceDate: row.double(1)),
                end: row.optionalDouble(2).map(Date.init(timeIntervalSinceReferenceDate:)),
                state: SessionState(rawValue: row.text(3)) ?? .closed,
                checkpoint: Date(timeIntervalSinceReferenceDate: row.double(4)),
                checkpointKind: CheckpointKind(rawValue: row.text(5)) ?? .heartbeat,
                detectedAt: row.optionalDouble(6).map(Date.init(timeIntervalSinceReferenceDate:)),
                timeZoneID: row.text(7),
                createdAt: Date(timeIntervalSinceReferenceDate: row.double(8)),
                updatedAt: Date(timeIntervalSinceReferenceDate: row.double(9))))
        }
        return result
    }

    public func session(id: UUID) throws -> WorkSession? {
        try loadSessions().first { $0.id == id }
    }

    public func upsert(_ s: WorkSession) throws {
        try db.transaction {
            try db.run("""
                INSERT INTO sessions(id, start, end, state, checkpoint, checkpoint_kind, detected_at, tz, created_at, updated_at)
                VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET start=excluded.start, end=excluded.end, state=excluded.state,
                    checkpoint=excluded.checkpoint, checkpoint_kind=excluded.checkpoint_kind,
                    detected_at=excluded.detected_at, tz=excluded.tz, updated_at=excluded.updated_at
                """, [
                    .text(s.id.uuidString),
                    .double(s.start.timeIntervalSinceReferenceDate),
                    s.end.map { .double($0.timeIntervalSinceReferenceDate) } ?? .null,
                    .text(s.state.rawValue),
                    .double(s.checkpoint.timeIntervalSinceReferenceDate),
                    .text(s.checkpointKind.rawValue),
                    s.detectedAt.map { .double($0.timeIntervalSinceReferenceDate) } ?? .null,
                    .text(s.timeZoneID),
                    .double(s.createdAt.timeIntervalSinceReferenceDate),
                    .double(s.updatedAt.timeIntervalSinceReferenceDate),
                ])
            try bumpRevision()
        }
    }

    /// Checkpoints are frequent and tiny; they do not bump the data revision.
    public func updateCheckpoint(id: UUID, at: Date, kind: CheckpointKind) throws {
        try db.run("UPDATE sessions SET checkpoint = ?, checkpoint_kind = ? WHERE id = ? AND state = 'active'",
                   [.double(at.timeIntervalSinceReferenceDate), .text(kind.rawValue), .text(id.uuidString)])
    }

    public func deleteSession(id: UUID) throws {
        try db.transaction {
            try db.run("DELETE FROM sessions WHERE id = ?", [.text(id.uuidString)])
            try bumpRevision()
        }
    }

    // MARK: Audit log

    /// Durable record of every Start/Stop/edit/recovery action.
    public func logEvent(_ kind: String, sessionID: UUID?, at: Date, detail: String = "") throws {
        try db.run("INSERT INTO events(at, kind, session_id, detail) VALUES(?, ?, ?, ?)",
                   [.double(at.timeIntervalSinceReferenceDate), .text(kind),
                    sessionID.map { .text($0.uuidString) } ?? .null, .text(detail)])
    }

    public struct Event: Equatable {
        public var at: Date
        public var kind: String
        public var sessionID: UUID?
        public var detail: String
    }

    public func events(limit: Int = 500) throws -> [Event] {
        var result: [Event] = []
        try db.query("SELECT at, kind, session_id, detail FROM events ORDER BY id DESC LIMIT ?", [.int(Int64(limit))]) { row in
            result.append(Event(at: Date(timeIntervalSinceReferenceDate: row.double(0)), kind: row.text(1),
                                sessionID: row.optionalText(2).flatMap(UUID.init(uuidString:)), detail: row.text(3)))
        }
        return result
    }

    // MARK: Settings

    public func loadSettings() -> WorkdaySettings {
        var json: String?
        try? db.query("SELECT json FROM settings WHERE id = 1") { json = $0.text(0) }
        guard let json, let data = json.data(using: .utf8),
              let settings = try? JSONDecoder().decode(WorkdaySettings.self, from: data) else {
            return WorkdaySettings()
        }
        return settings.normalized()
    }

    public func saveSettings(_ settings: WorkdaySettings) throws {
        let data = try JSONEncoder().encode(settings.normalized())
        try db.transaction {
            try db.run("INSERT INTO settings(id, json) VALUES(1, ?) ON CONFLICT(id) DO UPDATE SET json = excluded.json",
                       [.text(String(decoding: data, as: UTF8.self))])
            try bumpRevision()
        }
    }

    // MARK: Notification bookkeeping

    public func wasNotified(day: DayKey, kind: ReminderKind) -> Bool {
        var found = false
        try? db.query("SELECT 1 FROM notifications_sent WHERE day = ? AND kind = ?", [.text(day.description), .text(kind.rawValue)]) { _ in
            found = true
        }
        return found
    }

    /// Records a notification; returns false if it had already been recorded for that day.
    @discardableResult
    public func markNotified(day: DayKey, kind: ReminderKind, at: Date) throws -> Bool {
        try db.run("INSERT OR IGNORE INTO notifications_sent(day, kind, sent_at) VALUES(?, ?, ?)",
                   [.text(day.description), .text(kind.rawValue), .double(at.timeIntervalSinceReferenceDate)])
        return db.changes > 0
    }

    func notificationRecords() -> [(day: String, kind: String, sentAt: Double)] {
        var result: [(String, String, Double)] = []
        try? db.query("SELECT day, kind, sent_at FROM notifications_sent") { result.append(($0.text(0), $0.text(1), $0.double(2))) }
        return result
    }

    // MARK: Integrity

    /// Runs SQLite's integrity check and verifies the expected tables are readable.
    public static func validate(databaseAt path: String) throws -> (schemaVersion: Int, sessionCount: Int) {
        guard FileManager.default.fileExists(atPath: path) else { throw StoreError.invalidBackup("file is missing") }
        let db: SQLiteDatabase
        do { db = try SQLiteDatabase(path: path, readOnly: true) } catch { throw StoreError.invalidBackup("cannot be opened") }
        defer { db.close() }
        var integrity = ""
        do {
            try db.query("PRAGMA integrity_check") { integrity = $0.text(0) }
        } catch {
            throw StoreError.invalidBackup("not a readable database")
        }
        guard integrity == "ok" else { throw StoreError.invalidBackup("integrity check failed (\(integrity))") }
        var version = 0
        var count = -1
        do {
            try db.query("SELECT value FROM meta WHERE key = 'schema_version'") { version = Int($0.text(0)) ?? 0 }
            try db.query("SELECT COUNT(*) FROM sessions") { count = Int($0.int(0)) }
            try db.query("SELECT COUNT(*) FROM settings") { _ in }
        } catch {
            throw StoreError.invalidBackup("missing Workday tables")
        }
        guard version >= 1 else { throw StoreError.invalidBackup("missing schema version") }
        guard version <= schemaVersion else { throw StoreError.newerSchema(version) }
        return (version, count)
    }
}
