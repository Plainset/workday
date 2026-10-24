import Foundation

/// A backup file on disk with its validation result.
public struct BackupInfo: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        case automatic = "auto"
        case manual
        case safety

        public var label: String {
            switch self {
            case .automatic: return "Automatic"
            case .manual: return "Manual"
            case .safety: return "Pre-restore safety copy"
            }
        }
    }

    public var url: URL
    public var kind: Kind
    public var createdAt: Date
    public var sizeBytes: Int64
    /// `nil` when valid, otherwise the reason it can't be restored.
    public var problem: String?
    public var sessionCount: Int?

    public var id: String { url.lastPathComponent }
    public var isValid: Bool { problem == nil }
}

/// Versioned local backups using SQLite's online backup API (never a raw copy of a live database).
///
/// Policy: one automatic snapshot per calendar day whenever data changed since the last backup;
/// the newest 30 automatic snapshots are retained, plus the newest 20 manual and 10 safety copies.
/// Restores validate the backup first and always take a safety copy of the current data.
public final class BackupManager {
    public static let retention: [BackupInfo.Kind: Int] = [.automatic: 30, .manual: 20, .safety: 10]

    public let directory: URL
    private let store: WorkStore
    private let fileManager = FileManager.default

    public private(set) var lastError: String?

    public init(store: WorkStore, directory: URL) {
        self.store = store
        self.directory = directory
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f
    }()

    /// Owner-only permissions for the backups folder and every existing backup (upgrades from versions that
    /// created them with default permissions).
    public func tightenPermissions() {
        guard fileManager.fileExists(atPath: directory.path) else { return }
        try? OwnerOnly.createDirectory(at: directory)
        let urls = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in urls { OwnerOnly.restrict(file: url.path) }
    }

    // MARK: Listing

    /// All backups, newest first, each validated.
    public func list(validate: Bool = true) -> [BackupInfo] {
        let urls = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        var result: [BackupInfo] = []
        for url in urls where url.pathExtension == "sqlite" && url.lastPathComponent.hasPrefix("workday-") {
            let parts = url.deletingPathExtension().lastPathComponent.split(separator: "-")
            guard parts.count >= 3,
                  let kind = BackupInfo.Kind(rawValue: String(parts[1])),
                  let date = Self.stampFormatter.date(from: String(parts[2])) else { continue }
            let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0)
            var info = BackupInfo(url: url, kind: kind, createdAt: date, sizeBytes: size, problem: nil, sessionCount: nil)
            if validate {
                do {
                    let v = try WorkStore.validate(databaseAt: url.path)
                    info.sessionCount = v.sessionCount
                } catch {
                    info.problem = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                }
            }
            result.append(info)
        }
        return result.sorted { $0.createdAt > $1.createdAt }
    }

    /// Most recent automatic or manual backup (safety copies made before a restore don't count).
    public var lastBackupDate: Date? {
        list(validate: false).first { $0.kind != .safety }?.createdAt
    }

    // MARK: Creating

    /// Writes a snapshot, validates it, and prunes old files. Returns the new backup.
    @discardableResult
    public func createBackup(kind: BackupInfo.Kind, now: Date = Date()) throws -> BackupInfo {
        do {
            try OwnerOnly.createDirectory(at: directory)
            var stamp = Self.stampFormatter.string(from: now)
            var url = directory.appendingPathComponent("workday-\(kind.rawValue)-\(stamp).sqlite")
            var suffix = 1
            while fileManager.fileExists(atPath: url.path) {
                stamp = Self.stampFormatter.string(from: now.addingTimeInterval(TimeInterval(suffix)))
                url = directory.appendingPathComponent("workday-\(kind.rawValue)-\(stamp).sqlite")
                suffix += 1
            }
            let partial = url.appendingPathExtension("partial")
            try? fileManager.removeItem(at: partial)
            let revision = store.dataRevision
            do {
                let destination = try SQLiteDatabase(path: partial.path)
                try SQLiteDatabase.copy(from: store.db, to: destination)
                // Snapshots are self-contained single files.
                try destination.execute("PRAGMA journal_mode=DELETE")
                destination.close()
            }
            for suffix in ["-shm", "-wal"] {
                try? fileManager.removeItem(atPath: partial.path + suffix)
            }
            let validation = try WorkStore.validate(databaseAt: partial.path)
            try fileManager.moveItem(at: partial, to: url)
            OwnerOnly.restrict(file: url.path)
            if kind == .automatic || kind == .manual {
                try store.setMeta("last_backup_revision", String(revision))
            }
            try store.setMeta("last_backup_at", String(now.timeIntervalSinceReferenceDate))
            prune()
            lastError = nil
            let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0)
            return BackupInfo(url: url, kind: kind, createdAt: Self.stampFormatter.date(from: stamp) ?? now,
                              sizeBytes: size, problem: nil, sessionCount: validation.sessionCount)
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            try? store.setMeta("last_backup_error", lastError ?? "")
            throw error
        }
    }

    /// Daily automatic snapshot when data has changed since the last backup.
    /// Returns the backup created, or nil when none was needed.
    @discardableResult
    public func performAutomaticBackupIfNeeded(now: Date = Date(), calendar: Calendar = .current) throws -> BackupInfo? {
        let revision = store.dataRevision
        let lastRevision = Int(store.meta("last_backup_revision") ?? "-1") ?? -1
        guard revision != lastRevision else { return nil }
        if let lastAuto = list(validate: false).first(where: { $0.kind == .automatic }),
           calendar.isDate(lastAuto.createdAt, inSameDayAs: now) {
            return nil
        }
        return try createBackup(kind: .automatic, now: now)
    }

    /// Removes the oldest files beyond the retention limit per kind, plus stray partial files.
    public func prune() {
        let all = list(validate: false)
        for kind in BackupInfo.Kind.allCases {
            let keep = Self.retention[kind] ?? 30
            let ofKind = all.filter { $0.kind == kind }
            var doomed = Array(ofKind.dropFirst(keep))
            guard !doomed.isEmpty else { continue }
            // Never prune away the last known-good copy: if none of the kept files validates,
            // spare the newest valid one among those beyond the limit.
            let keptHasValid = ofKind.prefix(keep).contains { (try? WorkStore.validate(databaseAt: $0.url.path)) != nil }
            if !keptHasValid, let spare = doomed.firstIndex(where: { (try? WorkStore.validate(databaseAt: $0.url.path)) != nil }) {
                doomed.remove(at: spare)
            }
            for info in doomed {
                try? fileManager.removeItem(at: info.url)
            }
        }
        let urls = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in urls where url.pathExtension == "partial" || url.lastPathComponent.hasSuffix(".partial-shm")
            || url.lastPathComponent.hasSuffix(".partial-wal") {
            try? fileManager.removeItem(at: url)
        }
    }

    // MARK: Restoring

    /// Validates `backup`, takes a safety copy of current data, then replaces the live database contents
    /// atomically using the SQLite backup API. Returns the safety backup created.
    @discardableResult
    public func restore(_ backup: BackupInfo, now: Date = Date()) throws -> BackupInfo {
        // 1. Validate before touching anything.
        _ = try WorkStore.validate(databaseAt: backup.url.path)
        // 2. Preserve current data.
        let safety = try createBackup(kind: .safety, now: now)
        // 3. Replace contents. SQLite applies the copy as a single write transaction on the destination.
        let source = try SQLiteDatabase(path: backup.url.path, readOnly: true)
        defer { source.close() }
        // Notifications already delivered must not fire again after going back in time, and the current
        // launch-at-login choice is a device preference, not history — keep both across the restore.
        let sent = store.notificationRecords()
        let devicePreferences = ["login_item_enabled", "login_item_bundle_id"].compactMap { key in
            store.meta(key).map { (key, $0) }
        }
        do {
            try SQLiteDatabase.copy(from: source, to: store.db)
            for record in sent {
                try store.db.run("INSERT OR IGNORE INTO notifications_sent(day, kind, sent_at) VALUES(?, ?, ?)",
                                 [.text(record.day), .text(record.kind), .double(record.sentAt)])
            }
            for (key, value) in devicePreferences {
                try store.setMeta(key, value)
            }
            try store.migrate()
            try store.db.execute("PRAGMA journal_mode=WAL")
            try store.logEvent("restore", sessionID: nil, at: now, detail: backup.url.lastPathComponent)
            try store.bumpRevision()
        } catch {
            // Roll back to the safety copy if anything went wrong mid-way.
            if let safetySource = try? SQLiteDatabase(path: safety.url.path, readOnly: true) {
                try? SQLiteDatabase.copy(from: safetySource, to: store.db)
                safetySource.close()
            }
            throw error
        }
        return safety
    }
}

/// Owner-only (0700 directories, 0600 files) permissions for personal data.
public enum OwnerOnly {
    public static func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // Also tighten a directory created by an earlier version.
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    public static func restrict(file path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }
}

/// Standard on-disk locations. `WORKDAY_DATA_DIR` overrides the root (used for tests/demos).
public enum WorkdayPaths {
    public static var dataDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["WORKDAY_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Workday", isDirectory: true)
    }

    public static var databaseURL: URL { dataDirectory.appendingPathComponent("workday.sqlite") }
    public static var backupsDirectory: URL { dataDirectory.appendingPathComponent("Backups", isDirectory: true) }
    public static var lockURL: URL { dataDirectory.appendingPathComponent(".workday.lock") }

    public static var usesCustomDataDirectory: Bool {
        !(ProcessInfo.processInfo.environment["WORKDAY_DATA_DIR"] ?? "").isEmpty
    }
}

/// Ensures one running instance per data directory using an advisory `flock`.
/// The lock is released automatically by the OS if the process dies.
public final class SingleInstanceLock {
    private var fd: Int32 = -1

    public init?(url: URL) {
        try? OwnerOnly.createDirectory(at: url.deletingLastPathComponent())
        fd = open(url.path, O_CREAT | O_RDWR, 0o600)
        OwnerOnly.restrict(file: url.path)
        guard fd >= 0 else { return nil }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return nil
        }
    }

    deinit {
        if fd >= 0 {
            flock(fd, LOCK_UN)
            close(fd)
        }
    }
}
