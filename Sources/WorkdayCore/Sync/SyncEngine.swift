import Foundation

/// Another Mac seen in the sync folder.
public struct SyncPeer: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var lastSeen: Date?
}

/// What one sync pass did.
public struct SyncReport: Equatable, Sendable {
    public var published = 0
    public var applied = 0
    public var peers: [SyncPeer] = []
    /// Plain-language notes about records that were skipped or are still downloading.
    public var problems: [String] = []
    /// Whether this Mac's own running timer was started, stopped or changed by another Mac.
    public var localTimerChanged = false
    public var completedAt: Date
}

public enum SyncError: LocalizedError, Equatable {
    case folderMissing
    case notWritable(String)

    public var errorDescription: String? {
        switch self {
        case .folderMissing:
            return "The sync folder can't be found. If you use iCloud Drive, check that iCloud Drive is turned on in System Settings → your name → iCloud, or choose another folder."
        case .notWritable(let detail):
            return "Workday can't write to the sync folder (\(detail)). Check that the folder still exists and that you have permission to change it."
        }
    }
}

/// Serverless sync between the owner's Macs through a shared folder (normally in iCloud Drive).
///
/// Each Mac keeps its own SQLite database as the source of truth and exchanges change records:
///
///     <folder>/Workday Sync/devices/<deviceID>/device.json          name, epoch, latest sequence number
///     <folder>/Workday Sync/devices/<deviceID>/log-<firstSeq>.jsonl  immutable batches of records (JSON Lines)
///     <folder>/Workday Sync/devices/<deviceID>/snapshot.json         compacted full state at a sequence number
///
/// A device only ever writes inside its own folder, always via a temporary file renamed into place, so
/// there are no write conflicts. Local changes are found by comparing the database with `sync_versions`
/// (the last synced version of every record), so every kind of change — timer, edits, deletes, settings,
/// restores — is published the same way. Records are merged last-writer-wins by hybrid logical clock.
/// See docs/ARCHITECTURE.md → "Sync between Macs".
@MainActor
public final class SyncEngine {
    nonisolated public static let rootName = "Workday Sync"
    static let formatVersion = 1
    /// Once this many log files exist, they are folded into a snapshot.
    static let compactAfterSegments = 64
    /// A running session's checkpoint is shared at most this often (for display only).
    public static let checkpointPublishInterval: TimeInterval = 600
    static let deviceInfoRefresh: TimeInterval = 600

    public let ledger: WorkLedger
    public var clock: () -> Date
    private var store: WorkStore { ledger.store }
    private let fm = FileManager.default

    public init(ledger: WorkLedger, clock: (() -> Date)? = nil) {
        self.ledger = ledger
        self.clock = clock ?? ledger.clock
    }

    /// The iCloud Drive folder of the signed-in Apple ID (present only when iCloud Drive is on).
    nonisolated public static var iCloudDriveURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    }

    nonisolated public static func syncRoot(in folder: URL) -> URL { folder.appendingPathComponent(rootName, isDirectory: true) }

    // MARK: Pass

    /// Publishes local changes, then imports every other Mac's changes. Safe to call repeatedly.
    @discardableResult
    public func sync(folder: URL, deviceName: String) throws -> SyncReport {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else { throw SyncError.folderMissing }
        let me = store.deviceID
        let root = Self.syncRoot(in: folder)
        let devices = root.appendingPathComponent("devices", isDirectory: true)
        let mine = devices.appendingPathComponent(me, isDirectory: true)
        // Everything under the sync folder is untrusted: refuse links that could redirect writes or deletes.
        for dir in [root, devices, mine] where Self.isSymbolicLink(dir) {
            throw SyncError.notWritable("“\(dir.lastPathComponent)” is a link, not a folder")
        }
        do { try OwnerOnly.createDirectory(at: mine) } catch { throw SyncError.notWritable(error.localizedDescription) }
        guard Self.isRealDirectory(root), Self.isRealDirectory(devices), Self.isRealDirectory(mine) else {
            throw SyncError.notWritable("the sync folder isn't a normal folder")
        }
        OwnerOnly.restrictDirectory(root)
        OwnerOnly.restrictDirectory(devices)

        let now = clock()
        var report = SyncReport(completedAt: now)
        var hlc = HybridClock(device: me, last: store.meta("sync_hlc").flatMap(HybridTimestamp.init))
        let timerBefore = ledger.activeSession

        // A new folder (or one whose copy of this Mac's files was removed) starts a fresh log: everything
        // is published again as a snapshot and every peer is read from the beginning.
        let hasDeviceFile = fm.fileExists(atPath: mine.appendingPathComponent("device.json").path)
            || fm.fileExists(atPath: mine.appendingPathComponent(".device.json.icloud").path)
        let bootstrap = store.meta("sync_bound_folder") != root.path || !hasDeviceFile
        let peerIDs = peerFolders(in: devices, excluding: me)
        if bootstrap {
            // Only this engine's own files (a stale log from an earlier life of this device's folder).
            for name in (try? fm.contentsOfDirectory(atPath: mine.path)) ?? [] where Self.isOwnFileName(name) {
                try? fm.removeItem(at: mine.appendingPathComponent(name))
            }
            try store.db.transaction {
                try store.db.run("DELETE FROM meta WHERE key LIKE 'sync_cursor_%'")
                try store.setMeta("sync_seq", "0")
                try store.setMeta("sync_epoch", UUID().uuidString)
                try store.setMeta("sync_published_revision", "-1")
                try store.setMeta("sync_bound_folder", root.path)
            }
        }
        let epoch = store.meta("sync_epoch") ?? UUID().uuidString

        // 1. Publish local changes first, so they carry clocks before anything is merged in.
        var versions = try store.loadSyncVersions()
        var seq = Int64(store.meta("sync_seq") ?? "0") ?? 0
        try store.db.transaction {
            let records = try collectLocalChanges(&versions, clock: &hlc, now: now, bootstrap: bootstrap,
                                                  peersExist: !peerIDs.isEmpty)
            guard !records.isEmpty else { return }
            let first = seq + 1
            let numbered = records.enumerated().map { i, r -> SyncRecord in
                var r = r
                r.seq = first + Int64(i)
                return r
            }
            seq = first + Int64(records.count) - 1
            try store.setMeta("sync_seq", String(seq))
            // Written inside the transaction: if the file can't be written, nothing is marked as published.
            try writeSegment(numbered, firstSeq: first, in: mine)
            report.published = records.count
        }

        // 2. Import every other Mac.
        var changed = false
        for peer in peerIDs {
            changed = try importPeer(peer, from: devices.appendingPathComponent(peer, isDirectory: true),
                                     versions: &versions, clock: &hlc, now: now, report: &report) || changed
        }

        // 3. Compact, describe this device, remember state.
        let segments = listSegments(in: mine).filter(\.available)
        var compacted = false
        if bootstrap {
            // The bootstrap snapshot gets a sequence number of its own, so readers always see it as new.
            seq += 1
            try store.setMeta("sync_seq", String(seq))
        }
        if bootstrap || segments.count >= Self.compactAfterSegments {
            try writeSnapshot(versions: versions, seq: seq, epoch: epoch, in: mine, now: now)
            compacted = true
        }
        let name = SyncValidation.cleanName(deviceName)
        let lastInfo = Double(store.meta("sync_device_info_at") ?? "") ?? 0
        if report.published > 0 || compacted || store.meta("sync_published_name") != name
            || now.timeIntervalSinceReferenceDate - lastInfo >= Self.deviceInfoRefresh {
            try writeDeviceInfo(DeviceInfo(format: Self.formatVersion, device: me, name: name, epoch: epoch, seq: seq,
                                           updatedAt: now.timeIntervalSince1970), in: mine)
            try store.setMeta("sync_device_info_at", String(now.timeIntervalSinceReferenceDate))
            try store.setMeta("sync_published_name", name)
        }
        try store.setMeta("sync_hlc", hlc.last.description)
        try store.setMeta("sync_published_revision", String(store.dataRevision))
        try store.setMeta("sync_last_success", String(now.timeIntervalSinceReferenceDate))

        if changed {
            try ledger.reload()
            let after = ledger.activeSession
            report.localTimerChanged = after?.id != timerBefore?.id || after?.state != timerBefore?.state
        }
        return report
    }

    // MARK: Publishing

    private func collectLocalChanges(_ versions: inout [SyncVersionKey: SyncVersion], clock hlc: inout HybridClock,
                                     now: Date, bootstrap: Bool, peersExist: Bool) throws -> [SyncRecord] {
        let me = store.deviceID
        var out: [SyncRecord] = []
        func set(_ entity: SyncVersionKey.Entity, _ key: String, _ ts: HybridTimestamp, _ hash: String, deleted: Bool = false) throws {
            let k = SyncVersionKey(entity: entity, key: key)
            let v = SyncVersion(hlc: ts, hash: hash, deleted: deleted)
            versions[k] = v
            try store.setSyncVersion(k, v)
        }

        // Sessions and settings change only with the data revision (checkpoints don't bump it).
        if bootstrap || store.meta("sync_published_revision") != String(store.dataRevision) {
            var present = Set<String>()
            for s in try store.loadSessions() {
                let key = s.id.uuidString
                present.insert(key)
                let hash = SyncHash.session(s)
                let known = versions[SyncVersionKey(entity: .session, key: key)]
                if let known, !known.deleted, known.hash == hash { continue }
                let ts: HybridTimestamp
                if known == nil {
                    // Never synced: its own last-edit time orders it against other Macs' versions.
                    ts = HybridTimestamp(wall: HybridTimestamp.milliseconds(s.updatedAt), counter: 0, device: me)
                    hlc.observe(ts)
                } else {
                    ts = hlc.tick(now: now)
                }
                out.append(.session(s, hlc: ts))
                try set(.session, key, ts, hash)
            }
            for (k, v) in versions where k.entity == .session && !v.deleted && !present.contains(k.key) {
                let ts = hlc.tick(now: now)
                out.append(.tombstone(id: k.key, hlc: ts))
                try set(.session, k.key, ts, "", deleted: true)
            }
            let settings = store.loadSettings()
            for field in SyncedSetting.allCases {
                let value = field.value(in: settings)
                let known = versions[SyncVersionKey(entity: .setting, key: field.rawValue)]
                if known?.hash == String(value) { continue }
                // A Mac's settings from before sync never override another Mac's: a Mac joining an existing
                // sync folder adopts the settings already there.
                let ts = known == nil ? HybridTimestamp(wall: peersExist ? 0 : 1, counter: 0, device: me) : hlc.tick(now: now)
                out.append(.setting(field.rawValue, value: value, hlc: ts))
                try set(.setting, field.rawValue, ts, String(value))
            }
        }
        for record in store.notificationRecords() {
            let key = "\(record.day)|\(record.kind)"
            guard versions[SyncVersionKey(entity: .notified, key: key)] == nil else { continue }
            let ts = hlc.tick(now: now)
            out.append(.notified(day: record.day, reminder: record.kind, sentAt: record.sentAt, hlc: ts))
            try set(.notified, key, ts, "1")
        }
        // The running session's checkpoint (advisory; lets the other Mac show "last seen").
        if let active = ledger.activeSession {
            let published = Double(store.meta("sync_published_checkpoint") ?? "") ?? 0
            if active.checkpoint.timeIntervalSinceReferenceDate - published >= Self.checkpointPublishInterval {
                out.append(.checkpoint(of: active, hlc: hlc.tick(now: now)))
                try store.setMeta("sync_published_checkpoint", String(active.checkpoint.timeIntervalSinceReferenceDate))
            }
        }
        return out
    }

    private func writeSegment(_ records: [SyncRecord], firstSeq: Int64, in dir: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = Data()
        for r in records {
            data.append(try encoder.encode(r))
            data.append(0x0A)
        }
        try atomicWrite(data, to: dir.appendingPathComponent(String(format: "log-%012lld.jsonl", firstSeq)))
    }

    private func writeSnapshot(versions: [SyncVersionKey: SyncVersion], seq: Int64, epoch: String, in dir: URL, now: Date) throws {
        let sessions = Dictionary(try store.loadSessions().map { ($0.id.uuidString, $0) }, uniquingKeysWith: { a, _ in a })
        let settings = store.loadSettings()
        let notified = Dictionary(store.notificationRecords().map { ("\($0.day)|\($0.kind)", $0) }, uniquingKeysWith: { a, _ in a })
        var records: [SyncRecord] = []
        for (k, v) in versions.sorted(by: { $0.value.hlc < $1.value.hlc }) {
            switch k.entity {
            case .session:
                if v.deleted {
                    records.append(.tombstone(id: k.key, hlc: v.hlc))
                } else if let s = sessions[k.key] {
                    records.append(.session(s, hlc: v.hlc))
                }
            case .setting:
                if let field = SyncedSetting(rawValue: k.key) {
                    records.append(.setting(k.key, value: field.value(in: settings), hlc: v.hlc))
                }
            case .notified:
                if let n = notified[k.key] {
                    records.append(.notified(day: n.day, reminder: n.kind, sentAt: n.sentAt, hlc: v.hlc))
                }
            }
        }
        let snapshot = Snapshot(format: Self.formatVersion, device: store.deviceID, epoch: epoch, seq: seq,
                                createdAt: now.timeIntervalSince1970, records: records)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try atomicWrite(try encoder.encode(snapshot), to: dir.appendingPathComponent("snapshot.json"))
        // Every log record is now covered by the snapshot.
        for segment in listSegments(in: dir) where segment.start <= seq {
            try? fm.removeItem(at: segment.url)
        }
    }

    private func writeDeviceInfo(_ info: DeviceInfo, in dir: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try atomicWrite(try encoder.encode(info), to: dir.appendingPathComponent("device.json"))
    }

    /// Writes to a temporary file (owner-only) in the same folder, then renames it into place, so readers and
    /// iCloud only ever see complete files.
    private func atomicWrite(_ data: Data, to url: URL) throws {
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".tmp-\(UUID().uuidString)")
        guard fm.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw SyncError.notWritable("couldn't create \(url.lastPathComponent)")
        }
        if rename(tmp.path, url.path) != 0 {
            let reason = String(cString: strerror(errno))
            try? fm.removeItem(at: tmp)
            throw SyncError.notWritable(reason)
        }
    }

    // MARK: Importing

    private func peerFolders(in devices: URL, excluding me: String) -> [String] {
        let names = (try? fm.contentsOfDirectory(atPath: devices.path)) ?? []
        return names.filter { $0 != me && SyncValidation.isDeviceID($0)
            && Self.isRealDirectory(devices.appendingPathComponent($0)) }.sorted()
    }

    /// Imports one peer's new records. Returns true if local data changed.
    private func importPeer(_ peer: String, from dir: URL, versions: inout [SyncVersionKey: SyncVersion],
                            clock hlc: inout HybridClock, now: Date, report: inout SyncReport) throws -> Bool {
        guard let info = readDeviceInfo(in: dir), info.device == peer, SyncValidation.isDeviceID(info.epoch) else {
            return false
        }
        let name = SyncValidation.cleanName(info.name).isEmpty ? "Another Mac" : SyncValidation.cleanName(info.name)
        report.peers.append(SyncPeer(id: peer, name: name,
                                     lastSeen: info.updatedAt.isFinite ? Date(timeIntervalSince1970: info.updatedAt) : nil))
        let cursorKey = "sync_cursor_\(peer)"
        let stored = store.meta(cursorKey)?.split(separator: ":", maxSplits: 1).map(String.init) ?? []
        var cursor: Int64 = (stored.count == 2 && stored[0] == info.epoch) ? (Int64(stored[1]) ?? 0) : 0
        if info.seq <= cursor && stored.first == info.epoch { return false }

        var changed = false
        var unreadable = 0
        var waiting = false
        try store.db.transaction {
            let segments = listSegments(in: dir)
            let firstStart = segments.first?.start ?? Int64.max
            if firstStart > cursor + 1, let snapshot = readSnapshot(in: dir), snapshot.epoch == info.epoch,
               snapshot.device == peer, snapshot.seq > cursor {
                for record in snapshot.records {
                    switch try apply(record, from: peer, versions: &versions, clock: &hlc, now: now) {
                    case .applied: changed = true; report.applied += 1
                    case .invalid: unreadable += 1
                    case .ignored: break
                    }
                }
                cursor = snapshot.seq
            } else if firstStart > cursor + 1 && info.seq > cursor {
                waiting = true
            }
            if !waiting {
                for (i, segment) in segments.enumerated() {
                    let next = i + 1 < segments.count ? segments[i + 1].start : Int64.max
                    if next - 1 <= cursor { continue }
                    if segment.start > cursor + 1 || !segment.available { waiting = true; break }
                    guard let lines = readLines(segment.url) else { waiting = true; break }
                    for line in lines.complete {
                        guard line.count <= SyncValidation.maximumLineBytes,
                              let record = try? JSONDecoder().decode(SyncRecord.self, from: line),
                              let recordSeq = record.seq else { unreadable += 1; continue }
                        guard recordSeq > cursor else { continue }
                        switch try apply(record, from: peer, versions: &versions, clock: &hlc, now: now) {
                        case .applied: changed = true; report.applied += 1
                        case .invalid: unreadable += 1
                        case .ignored: break
                        }
                        cursor = max(cursor, recordSeq)
                    }
                    if lines.truncated { waiting = true; break }
                }
            }
            try store.setMeta(cursorKey, "\(info.epoch):\(cursor)")
        }
        if unreadable > 0 {
            report.problems.append("Skipped \(unreadable) unreadable change\(unreadable == 1 ? "" : "s") from “\(name)”.")
        }
        if waiting && cursor < info.seq {
            report.problems.append("Waiting for changes from “\(name)” to finish downloading.")
        }
        return changed
    }

    enum ApplyResult { case applied, ignored, invalid }

    private func apply(_ r: SyncRecord, from peer: String, versions: inout [SyncVersionKey: SyncVersion],
                       clock hlc: inout HybridClock, now: Date) throws -> ApplyResult {
        guard let ts = HybridTimestamp(r.hlc),
              ts.wall <= HybridTimestamp.milliseconds(now.addingTimeInterval(SyncValidation.maximumClockLead)) else {
            return .invalid
        }
        func newer(_ k: SyncVersionKey) -> Bool {
            guard let known = versions[k] else { return true }
            return ts > known.hlc
        }
        func record(_ k: SyncVersionKey, _ hash: String, deleted: Bool = false) throws {
            let v = SyncVersion(hlc: ts, hash: hash, deleted: deleted)
            versions[k] = v
            try store.setSyncVersion(k, v)
        }
        switch r.kind {
        case .session:
            let updated = Date(timeIntervalSince1970: Double(ts.wall) / 1000)
            guard let s = r.validatedSession(updatedAt: updated) else { return .invalid }
            hlc.observe(ts)
            let k = SyncVersionKey(entity: .session, key: s.id.uuidString)
            guard newer(k) else { return .ignored }
            try store.upsert(s)
            try store.logEvent("sync-apply", sessionID: s.id, at: now, detail: "from \(peer)")
            try record(k, SyncHash.session(s))
            return .applied
        case .tombstone:
            guard let idText = r.id, let id = UUID(uuidString: idText), id.uuidString == idText else { return .invalid }
            hlc.observe(ts)
            let k = SyncVersionKey(entity: .session, key: idText)
            guard newer(k) else { return .ignored }
            try store.deleteSession(id: id)
            try store.logEvent("sync-delete", sessionID: id, at: now, detail: "from \(peer)")
            try record(k, "", deleted: true)
            return .applied
        case .setting:
            guard let fieldText = r.field, let field = SyncedSetting(rawValue: fieldText), let value = r.value else { return .invalid }
            var settings = store.loadSettings()
            guard field.apply(value, to: &settings) else { return .invalid }
            hlc.observe(ts)
            let k = SyncVersionKey(entity: .setting, key: fieldText)
            guard newer(k) else { return .ignored }
            try store.saveSettings(settings)
            try record(k, String(value))
            return .applied
        case .notified:
            guard let day = r.day, SyncValidation.isDayText(day), let kindText = r.reminder,
                  ReminderKind(rawValue: kindText) != nil, let sentAt = r.sentAt,
                  SyncValidation.isPlausibleInstant(sentAt) else { return .invalid }
            hlc.observe(ts)
            let k = SyncVersionKey(entity: .notified, key: "\(day)|\(kindText)")
            try store.db.run("INSERT OR IGNORE INTO notifications_sent(day, kind, sent_at) VALUES(?, ?, ?)",
                             [.text(day), .text(kindText), .double(sentAt)])
            let inserted = store.db.changes > 0
            if versions[k] == nil { try record(k, "1") }
            return inserted ? .applied : .ignored
        case .checkpoint:
            guard let idText = r.id, let id = UUID(uuidString: idText), let cp = r.checkpoint,
                  SyncValidation.isPlausibleInstant(cp), let kindText = r.checkpointKind,
                  let kind = CheckpointKind(rawValue: kindText) else { return .invalid }
            hlc.observe(ts)
            // Advisory: only moves a still-running session of the sending Mac forward.
            guard let s = try store.session(id: id), s.state == .active, s.ownerDevice == peer,
                  cp > s.checkpoint.timeIntervalSinceReferenceDate else { return .ignored }
            try store.updateCheckpoint(id: id, at: Date(timeIntervalSinceReferenceDate: cp), kind: kind)
            return .applied
        }
    }

    // MARK: Reading files

    struct Segment {
        var start: Int64
        var url: URL
        /// False while iCloud only has a placeholder for it (download requested).
        var available: Bool
    }

    /// Log files sorted by first sequence number. Placeholders are listed as unavailable and downloaded.
    private func listSegments(in dir: URL) -> [Segment] {
        let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        var result: [Int64: Segment] = [:]
        for name in names {
            var real = name
            var available = true
            if name.hasPrefix("."), name.hasSuffix(".icloud") {
                real = String(name.dropFirst().dropLast(".icloud".count))
                available = false
            }
            guard real.hasPrefix("log-"), real.hasSuffix(".jsonl"),
                  let start = Int64(real.dropFirst(4).dropLast(6)), start > 0 else { continue }
            let url = dir.appendingPathComponent(real)
            if !available { requestDownload(url) }
            if result[start]?.available != true { result[start] = Segment(start: start, url: url, available: available) }
        }
        return result.values.sorted { $0.start < $1.start }
    }

    private func requestDownload(_ url: URL) {
        try? fm.startDownloadingUbiquitousItem(at: url)
    }

    /// Reads a bounded regular file (never through a link), asking iCloud to download it if only a
    /// placeholder is present.
    private func readBounded(_ url: URL) -> Data? {
        let placeholder = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud")
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else {
            if errno == ENOENT, fm.fileExists(atPath: placeholder.path) { requestDownload(url) }
            return nil
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size <= off_t(SyncValidation.maximumFileBytes) else { return nil }
        guard let data = try? handle.read(upToCount: SyncValidation.maximumFileBytes + 1),
              data.count <= SyncValidation.maximumFileBytes else { return nil }
        return data
    }

    nonisolated static func isSymbolicLink(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK
    }

    nonisolated static func isRealDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    /// Names this engine writes in its own device folder.
    nonisolated static func isOwnFileName(_ name: String) -> Bool {
        name == "device.json" || name == "snapshot.json" || name.hasPrefix(".tmp-")
            || (name.hasPrefix("log-") && name.hasSuffix(".jsonl"))
            || (name.hasPrefix(".") && name.hasSuffix(".icloud"))
    }

    struct Lines {
        var complete: [Data]
        /// True if the last line has no newline yet (a partially synced file); it is not applied.
        var truncated: Bool
    }

    private func readLines(_ url: URL) -> Lines? {
        guard let data = readBounded(url) else { return nil }
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true).map { Data($0) }
        let truncated = !data.isEmpty && data.last != 0x0A
        if truncated { lines.removeLast() }
        return Lines(complete: lines, truncated: truncated)
    }

    private func readDeviceInfo(in dir: URL) -> DeviceInfo? {
        guard let data = readBounded(dir.appendingPathComponent("device.json")), data.count <= 4096 else { return nil }
        return try? JSONDecoder().decode(DeviceInfo.self, from: data)
    }

    private func readSnapshot(in dir: URL) -> Snapshot? {
        guard let data = readBounded(dir.appendingPathComponent("snapshot.json")) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    struct DeviceInfo: Codable {
        var format: Int
        var device: String
        var name: String
        var epoch: String
        var seq: Int64
        /// Seconds since 1970.
        var updatedAt: Double
    }

    struct Snapshot: Codable {
        var format: Int
        var device: String
        var epoch: String
        var seq: Int64
        var createdAt: Double
        var records: [SyncRecord]
    }
}

// MARK: - Version table

public struct SyncVersionKey: Hashable, Sendable {
    public enum Entity: String, Sendable { case session, setting, notified }
    public var entity: Entity
    public var key: String
}

public struct SyncVersion: Equatable, Sendable {
    public var hlc: HybridTimestamp
    public var hash: String
    public var deleted: Bool
}

extension WorkStore {
    public func loadSyncVersions() throws -> [SyncVersionKey: SyncVersion] {
        var result: [SyncVersionKey: SyncVersion] = [:]
        try db.query("SELECT entity, key, hlc, hash, deleted FROM sync_versions") { row in
            guard let entity = SyncVersionKey.Entity(rawValue: row.text(0)), let hlc = HybridTimestamp(row.text(2)) else { return }
            result[SyncVersionKey(entity: entity, key: row.text(1))] = SyncVersion(hlc: hlc, hash: row.text(3), deleted: row.int(4) != 0)
        }
        return result
    }

    func setSyncVersion(_ key: SyncVersionKey, _ v: SyncVersion) throws {
        try db.run("""
            INSERT INTO sync_versions(entity, key, hlc, hash, deleted) VALUES(?, ?, ?, ?, ?)
            ON CONFLICT(entity, key) DO UPDATE SET hlc = excluded.hlc, hash = excluded.hash, deleted = excluded.deleted
            """, [.text(key.entity.rawValue), .text(key.key), .text(v.hlc.description), .text(v.hash), .int(v.deleted ? 1 : 0)])
    }
}
