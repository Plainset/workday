import Foundation
import Testing
@testable import WorkdayCore

/// One simulated Mac: its own database and clock, sharing a sync folder with the others.
@MainActor
final class SimMac {
    let name: String
    let ledger: WorkLedger
    let clock: TestClock
    let dir: URL
    let engine: SyncEngine
    let folder: URL

    init(_ name: String, at start: Date, folder: URL) throws {
        let (ledger, clock, dir) = try makeLedger(at: start)
        self.name = name
        self.ledger = ledger
        self.clock = clock
        self.dir = dir
        self.folder = folder
        engine = SyncEngine(ledger: ledger)
    }

    var id: String { ledger.deviceID }

    @discardableResult
    func sync() throws -> SyncReport { try engine.sync(folder: folder, deviceName: name) }

    /// Simulates a relaunch of the app on this Mac (fresh ledger over the same database).
    func relaunch() throws -> WorkLedger {
        let store = try WorkStore(path: dir.appendingPathComponent("workday.sqlite").path)
        let relaunched = try WorkLedger(store: store, calendar: calendar(), clock: { [clock] in clock.now })
        try relaunched.detectInterruptions()
        return relaunched
    }
}

/// Runs passes until both Macs have nothing more to exchange.
@MainActor
func converge(_ macs: SimMac...) throws {
    for _ in 0..<3 { for m in macs { try m.sync() } }
}

/// Comparable content of a ledger's sessions (ignoring bookkeeping timestamps).
@MainActor
func content(_ l: WorkLedger) -> [String] {
    l.sessions.map { "\($0.id) \($0.start.timeIntervalSinceReferenceDate) \($0.end?.timeIntervalSinceReferenceDate ?? -1) \($0.state.rawValue) \($0.ownerDevice)" }.sorted()
}

/// Writes a fake peer's folder by hand (for malformed, truncated and out-of-order input).
func writePeer(_ folder: URL, device: String, epoch: String, seq: Int64, files: [String: Data], name: String = "Fake") throws {
    let dir = SyncEngine.syncRoot(in: folder).appendingPathComponent("devices/\(device)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let info = "{\"device\":\"\(device)\",\"epoch\":\"\(epoch)\",\"format\":1,\"name\":\"\(name)\",\"seq\":\(seq),\"updatedAt\":1}"
    try Data(info.utf8).write(to: dir.appendingPathComponent("device.json"))
    for (file, data) in files { try data.write(to: dir.appendingPathComponent(file)) }
}

func line(_ r: SyncRecord, seq: Int64) throws -> Data {
    var r = r
    r.seq = seq
    let e = JSONEncoder()
    e.outputFormatting = .sortedKeys
    return try e.encode(r) + Data([0x0A])
}

@MainActor
@Suite("Sync between Macs")
struct SyncTests {
    let t0 = date(2026, 11, 16, 9, 0)

    func pair() throws -> (SimMac, SimMac) {
        let folder = tempDir()
        return (try SimMac("Mini", at: t0, folder: folder), try SimMac("Laptop", at: t0, folder: folder))
    }

    @Test("Sessions, edits and deletes converge on both Macs")
    func basicConvergence() throws {
        let (a, b) = try pair()
        let s = try a.ledger.addSession(start: date(2026, 11, 16, 7), end: date(2026, 11, 16, 8))
        try converge(a, b)
        #expect(content(a.ledger) == content(b.ledger))
        #expect(b.ledger.sessions.count == 1)

        b.clock.advance(60)
        try b.ledger.updateSession(id: s.id, start: date(2026, 11, 16, 6, 30), end: date(2026, 11, 16, 8))
        try converge(a, b)
        #expect(a.ledger.sessions.first?.start == date(2026, 11, 16, 6, 30))

        a.clock.advance(120)
        try a.ledger.deleteSession(id: s.id)
        try converge(a, b)
        #expect(a.ledger.sessions.isEmpty && b.ledger.sessions.isEmpty)
    }

    @Test("Last writer wins, and a Mac with a slow clock still wins with a later edit")
    func lastWriterWinsWithSkew() throws {
        let (a, b) = try pair()
        b.clock.now = t0.addingTimeInterval(-3600)  // laptop clock one hour behind
        let s = try a.ledger.addSession(start: date(2026, 11, 16, 6), end: date(2026, 11, 16, 7))
        try converge(a, b)
        a.clock.advance(60)
        try a.ledger.updateSession(id: s.id, start: date(2026, 11, 16, 6), end: date(2026, 11, 16, 7, 30))
        try converge(a, b)
        #expect(b.ledger.sessions.first?.end == date(2026, 11, 16, 7, 30))

        // B edits after seeing A's edit, but its wall clock reads an hour earlier.
        b.clock.advance(120)
        try b.ledger.updateSession(id: s.id, start: date(2026, 11, 16, 5), end: date(2026, 11, 16, 7, 30))
        try converge(a, b)
        #expect(a.ledger.sessions.first?.start == date(2026, 11, 16, 5))
        #expect(content(a.ledger) == content(b.ledger))
    }

    @Test("Concurrent edits: the later one wins on both Macs")
    func concurrentEdits() throws {
        let (a, b) = try pair()
        let s = try a.ledger.addSession(start: date(2026, 11, 16, 6), end: date(2026, 11, 16, 7))
        try converge(a, b)
        a.clock.advance(60)
        b.clock.advance(90)
        try a.ledger.updateSession(id: s.id, start: date(2026, 11, 16, 6), end: date(2026, 11, 16, 7, 10))
        try b.ledger.updateSession(id: s.id, start: date(2026, 11, 16, 6), end: date(2026, 11, 16, 7, 20))
        try converge(a, b)
        #expect(a.ledger.sessions.first?.end == date(2026, 11, 16, 7, 20))
        #expect(content(a.ledger) == content(b.ledger))
    }

    @Test("A delete beats an older edit that arrives later")
    func tombstoneBeatsLateEdit() throws {
        let (a, b) = try pair()
        let s = try a.ledger.addSession(start: date(2026, 11, 16, 6), end: date(2026, 11, 16, 7))
        try converge(a, b)
        b.clock.advance(60)
        try b.ledger.updateSession(id: s.id, start: date(2026, 11, 16, 6), end: date(2026, 11, 16, 7, 30)) // not synced yet
        a.clock.advance(300)
        try a.ledger.deleteSession(id: s.id)
        try a.sync()
        try converge(b, a)
        #expect(a.ledger.sessions.isEmpty)
        #expect(b.ledger.sessions.isEmpty)
    }

    @Test("Re-applying records is a no-op, and out-of-order records resolve by clock")
    func idempotentAndOutOfOrder() throws {
        let (a, b) = try pair()
        try a.ledger.addSession(start: date(2026, 11, 16, 6), end: date(2026, 11, 16, 7))
        try converge(a, b)
        let before = content(b.ledger)
        let revision = b.ledger.store.dataRevision
        // Forget how far A's log was read: everything is applied again.
        try b.ledger.store.db.run("DELETE FROM meta WHERE key LIKE 'sync_cursor_%'")
        let report = try b.sync()
        #expect(report.applied == 0)
        #expect(content(b.ledger) == before)
        #expect(b.ledger.store.dataRevision == revision)

        // A peer whose log holds a newer edit first and an older one after it, then a tombstone before a create.
        let peer = UUID().uuidString
        let id = UUID()
        func ts(_ ms: Int64) -> HybridTimestamp { HybridTimestamp(wall: ms, counter: 0, device: peer) }
        let base = HybridTimestamp.milliseconds(t0)
        var newer = WorkSession(id: id, start: date(2026, 11, 15, 9), end: date(2026, 11, 15, 12), state: .closed, ownerDevice: peer)
        var older = newer
        older.end = date(2026, 11, 15, 10)
        newer.createdAt = date(2026, 11, 15, 12)
        older.createdAt = newer.createdAt
        let gone = UUID()
        let goneSession = WorkSession(id: gone, start: date(2026, 11, 14, 9), end: date(2026, 11, 14, 10), state: .closed,
                                      createdAt: date(2026, 11, 14, 10), ownerDevice: peer)
        var log = Data()
        log += try line(.session(newer, hlc: ts(base + 2000)), seq: 1)
        log += try line(.session(older, hlc: ts(base + 1000)), seq: 2)
        log += try line(.tombstone(id: gone.uuidString, hlc: ts(base + 5000)), seq: 3)
        log += try line(.session(goneSession, hlc: ts(base + 4000)), seq: 4)
        try writePeer(a.folder, device: peer, epoch: UUID().uuidString, seq: 4, files: ["log-000000000001.jsonl": log])
        try b.sync()
        #expect(b.ledger.sessions.first { $0.id == id }?.end == date(2026, 11, 15, 12))
        #expect(!b.ledger.sessions.contains { $0.id == gone })
    }

    @Test("Truncated and corrupt records are skipped without crashing; a truncated tail is read once complete")
    func truncatedAndCorrupt() throws {
        let (a, _) = try pair()
        let peer = UUID().uuidString
        let epoch = UUID().uuidString
        let base = HybridTimestamp.milliseconds(t0)
        func s(_ h: Int) -> WorkSession {
            WorkSession(start: date(2026, 11, 10, h), end: date(2026, 11, 10, h + 1), state: .closed,
                        createdAt: date(2026, 11, 10, h + 1), ownerDevice: peer)
        }
        let first = try line(.session(s(8), hlc: HybridTimestamp(wall: base, counter: 0, device: peer)), seq: 1)
        let garbage = Data("{not json at all\n".utf8)
        var bad = SyncRecord.session(s(10), hlc: HybridTimestamp(wall: base, counter: 1, device: peer))
        bad.end = bad.start! - 60  // ends before it starts
        let invalid = try line(bad, seq: 3)
        let last = try line(.session(s(12), hlc: HybridTimestamp(wall: base, counter: 2, device: peer)), seq: 4)
        let partial = last.prefix(last.count / 2)
        try writePeer(a.folder, device: peer, epoch: epoch, seq: 4,
                      files: ["log-000000000001.jsonl": first + garbage + invalid + partial])
        let report = try a.sync()
        #expect(a.ledger.sessions.count == 1)
        #expect(report.problems.contains { $0.contains("unreadable") })
        #expect(report.problems.contains { $0.contains("Waiting") })

        try writePeer(a.folder, device: peer, epoch: epoch, seq: 4, files: ["log-000000000001.jsonl": first + garbage + invalid + last])
        try a.sync()
        #expect(a.ledger.sessions.count == 2)

        // Oversized and hostile files are ignored.
        let other = UUID().uuidString
        try writePeer(a.folder, device: other, epoch: UUID().uuidString, seq: 1,
                      files: ["log-000000000001.jsonl": Data(repeating: 0x41, count: SyncValidation.maximumFileBytes + 1)])
        try a.sync()
        #expect(a.ledger.sessions.count == 2)
    }

    @Test("Overlapping history from two Macs is imported, listed, counted once, and resolvable")
    func overlapImport() throws {
        let (a, b) = try pair()
        try a.ledger.addSession(start: date(2026, 11, 15, 9), end: date(2026, 11, 15, 12))
        try b.ledger.addSession(start: date(2026, 11, 15, 10), end: date(2026, 11, 15, 13))
        try converge(a, b)
        let day = DayKey(date(2026, 11, 15, 12), calendar: calendar())
        #expect(a.ledger.sessions.count == 2)
        #expect(a.ledger.total(for: day) == 4 * 3600)   // 9–13 once, not 6 h
        #expect(b.ledger.total(for: day) == 4 * 3600)
        let conflicts = a.ledger.overlapConflicts()
        #expect(conflicts.count == 1)
        #expect(conflicts[0].overlap.duration == 2 * 3600)

        a.clock.advance(60)
        try a.ledger.mergeOverlap(conflicts[0].first.id, conflicts[0].second.id)
        try converge(a, b)
        #expect(b.ledger.sessions.count == 1)
        let merged = b.ledger.sessions[0]
        #expect(merged.start == date(2026, 11, 15, 9))
        #expect(merged.end == date(2026, 11, 15, 13))
        #expect(b.ledger.overlapConflicts().isEmpty)
    }

    @Test("Keeping one of two overlapping sessions deletes the other everywhere")
    func overlapKeepOne() throws {
        let (a, b) = try pair()
        let mine = try a.ledger.addSession(start: date(2026, 11, 15, 9), end: date(2026, 11, 15, 12))
        let theirs = try b.ledger.addSession(start: date(2026, 11, 15, 9), end: date(2026, 11, 15, 12))
        try converge(a, b)
        b.clock.advance(60)
        try b.ledger.resolveOverlap(keep: theirs.id, discard: mine.id)
        try converge(a, b)
        #expect(a.ledger.sessions.map(\.id) == [theirs.id])
    }

    @Test("A running timer shows on the other Mac, isn't flagged as interrupted there, and can be stopped there")
    func remoteRunningTimer() throws {
        let (a, b) = try pair()
        try a.ledger.start()
        try converge(a, b)
        #expect(!b.ledger.isRunning)
        #expect(b.ledger.remoteActiveSessions.count == 1)
        b.clock.advance(1800)
        #expect(b.ledger.total(for: b.ledger.today()) == 1800)
        #expect(b.ledger.elapsed(of: b.ledger.remoteActiveSessions[0]) == 1800)

        // A relaunch on B never turns A's running session into an interruption.
        let relaunched = try b.relaunch()
        #expect(relaunched.pendingRecoveries.isEmpty)
        #expect(relaunched.remoteActiveSessions.count == 1)
        try b.ledger.reload()

        // Starting on B while A runs is refused with a clear reason…
        #expect(throws: LedgerError.runningOnOtherMac) { try b.ledger.start() }
        // …unless B stops it there and starts here.
        try b.ledger.stopRemoteAndStart(remoteID: b.ledger.remoteActiveSessions[0].id)
        #expect(b.ledger.isRunning)
        a.clock.now = b.clock.now
        let report = try a.sync()
        _ = report
        try converge(a, b)
        #expect(!a.ledger.isRunning)
        #expect(a.ledger.sessions.first { $0.ownerDevice == a.id }?.end == b.clock.now)
        #expect(a.ledger.remoteActiveSessions.count == 1)
        a.clock.advance(600)
        #expect(a.ledger.total(for: a.ledger.today()) == 2400)

        // Stopping on B stops it everywhere.
        b.clock.now = a.clock.now
        try b.ledger.stop()
        try converge(a, b)
        #expect(a.ledger.remoteActiveSessions.isEmpty)
        #expect(content(a.ledger) == content(b.ledger))
    }

    @Test("Only this Mac's own stale session becomes an interruption on relaunch")
    func localInterruptionStillDetected() throws {
        let (a, b) = try pair()
        try a.ledger.start()
        try converge(a, b)
        a.clock.advance(3600)
        let relaunched = try a.relaunch()
        #expect(relaunched.pendingRecoveries.count == 1)
        try a.ledger.reload()
        try converge(a, b)
        #expect(b.ledger.sessions.first?.state == .interrupted)
        #expect(b.ledger.pendingRecoveries.isEmpty)   // decided on the Mac that owns it
    }

    @Test("Checkpoints of a running session travel occasionally, without overriding a stop")
    func checkpointsAreAdvisory() throws {
        let (a, b) = try pair()
        try a.ledger.start()
        try converge(a, b)
        a.clock.advance(SyncEngine.checkpointPublishInterval + 30)
        a.ledger.checkpoint(kind: .heartbeat)
        try converge(a, b)
        #expect(b.ledger.remoteActiveSessions.first?.checkpoint == a.clock.now)
        // A stop issued on B wins even if A publishes a later checkpoint afterwards.
        b.clock.now = a.clock.now.addingTimeInterval(10)
        try b.ledger.stopRemoteAndStart(remoteID: b.ledger.remoteActiveSessions[0].id)
        try b.sync()
        a.clock.advance(SyncEngine.checkpointPublishInterval + 60)
        a.ledger.checkpoint(kind: .heartbeat)
        try converge(a, b)
        #expect(!a.ledger.isRunning)
        #expect(a.ledger.remoteActiveSessions.count == 1)
    }

    @Test("Synced settings travel; device-local settings stay; a joining Mac adopts existing settings")
    func settingsSync() throws {
        let (a, b) = try pair()
        try a.ledger.updateSettings {
            $0.dailyGoalMinutes = 7 * 60
            $0.launchAtLoginInitialized = true
            $0.hasCompletedFirstLaunch = true
        }
        try b.ledger.updateSettings { $0.dailyGoalMinutes = 9 * 60 }
        try a.sync()   // A enables first
        try converge(b, a)
        #expect(b.ledger.settings.dailyGoalMinutes == 7 * 60)
        #expect(b.ledger.settings.launchAtLoginInitialized == false)
        #expect(b.ledger.settings.hasCompletedFirstLaunch == false)

        b.clock.advance(60)
        try b.ledger.updateSettings {
            $0.stopReminderEnabled = true
            $0.stopReminderMinutes = 17 * 60 + 45
            $0.hasCompletedFirstLaunch = true
        }
        try converge(a, b)
        #expect(a.ledger.settings.stopReminderEnabled)
        #expect(a.ledger.settings.stopReminderMinutes == 17 * 60 + 45)
        #expect(a.ledger.settings.dailyGoalMinutes == 7 * 60)
        #expect(a.ledger.settings.launchAtLoginInitialized == true)
    }

    @Test("A goal notification sent on one Mac is recorded on the other")
    func notificationsSync() throws {
        let (a, b) = try pair()
        let today = a.ledger.today()
        try a.ledger.store.markNotified(day: today, kind: .goalReached, at: a.clock.now)
        try converge(a, b)
        #expect(b.ledger.store.wasNotified(day: today, kind: .goalReached))
        #expect(!b.ledger.store.wasNotified(day: today, kind: .stopReminder))
    }

    @Test("Restoring a backup with sync on publishes the restored state instead of being reverted")
    func restoreWithSync() throws {
        let (a, b) = try pair()
        let s1 = try a.ledger.addSession(start: date(2026, 11, 14, 9), end: date(2026, 11, 14, 10))
        let s2 = try a.ledger.addSession(start: date(2026, 11, 14, 11), end: date(2026, 11, 14, 12))
        try converge(a, b)
        let backups = BackupManager(store: a.ledger.store, directory: a.dir.appendingPathComponent("Backups"))
        let backup = try backups.createBackup(kind: .manual, now: a.clock.now)

        a.clock.advance(60)
        b.clock.advance(60)
        try a.ledger.deleteSession(id: s2.id)
        let s3 = try b.ledger.addSession(start: date(2026, 11, 14, 13), end: date(2026, 11, 14, 14))
        try converge(a, b)
        let afterDelete = Set(b.ledger.sessions.map(\.id))
        #expect(afterDelete == [s1.id, s3.id])

        a.clock.advance(60)
        try backups.restore(backup, now: a.clock.now)
        try a.ledger.reload()
        try converge(a, b)
        let ids = Set(b.ledger.sessions.map(\.id))
        #expect(ids == [s1.id, s2.id])          // the restored state, published as new edits
        #expect(content(a.ledger) == content(b.ledger))
        #expect(a.ledger.store.deviceID == a.id)
    }

    @Test("Many small changes are compacted into a snapshot that a new Mac can read")
    func compactionAndLateJoiner() throws {
        let (a, b) = try pair()
        var last: WorkSession?
        for i in 0..<(SyncEngine.compactAfterSegments + 5) {
            a.clock.advance(60)
            last = try a.ledger.addSession(start: date(2026, 10, 1).addingTimeInterval(Double(i) * 7200),
                                           end: date(2026, 10, 1).addingTimeInterval(Double(i) * 7200 + 3600))
            try a.sync()
        }
        let mine = SyncEngine.syncRoot(in: a.folder).appendingPathComponent("devices/\(a.id)")
        let files = try FileManager.default.contentsOfDirectory(atPath: mine.path)
        #expect(files.contains("snapshot.json"))
        #expect(files.filter { $0.hasPrefix("log-") }.count < SyncEngine.compactAfterSegments)
        try converge(b, a)
        #expect(b.ledger.sessions.count == SyncEngine.compactAfterSegments + 5)
        #expect(b.ledger.sessions.contains { $0.id == last?.id })
    }

    @Test("Sync files are owner-only and a missing folder is reported plainly")
    func permissionsAndMissingFolder() throws {
        let (a, _) = try pair()
        try a.ledger.addSession(start: date(2026, 11, 16, 6), end: date(2026, 11, 16, 7))
        try a.sync()
        let mine = SyncEngine.syncRoot(in: a.folder).appendingPathComponent("devices/\(a.id)")
        let perms = { (path: String) in (try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue ?? -1 }
        #expect(try perms(mine.path) == 0o700)
        for file in try FileManager.default.contentsOfDirectory(atPath: mine.path) {
            #expect(try perms(mine.appendingPathComponent(file).path) == 0o600)
        }
        let missing = a.folder.appendingPathComponent("nope")
        #expect(throws: SyncError.folderMissing) { try a.engine.sync(folder: missing, deviceName: "x") }
    }

    @Test("A placeholder that iCloud hasn't downloaded yet is waited for, not skipped")
    func placeholderWaits() throws {
        let (a, _) = try pair()
        let peer = UUID().uuidString
        try writePeer(a.folder, device: peer, epoch: UUID().uuidString, seq: 3,
                      files: [".log-000000000001.jsonl.icloud": Data("placeholder".utf8)])
        let report = try a.sync()
        #expect(report.problems.contains { $0.contains("Waiting") })
        #expect(a.ledger.store.meta("sync_cursor_\(peer)")?.hasSuffix(":0") == true)
    }

    @Test("Moving to a new sync folder publishes everything again")
    func newFolderRebootstraps() throws {
        let (a, _) = try pair()
        try a.ledger.addSession(start: date(2026, 11, 16, 6), end: date(2026, 11, 16, 7))
        try a.sync()
        let other = tempDir()
        let fresh = try SimMac("Other", at: t0, folder: other)
        try a.engine.sync(folder: other, deviceName: "Mini")
        try fresh.sync()
        #expect(fresh.ledger.sessions.count == 1)
    }
}

@Suite("Schema v2 migration")
struct SchemaMigrationTests {
    @Test("A real v1 database file upgrades to v2: sessions owned by this device, data intact")
    func v1ToV2() throws {
        let path = tempDir().appendingPathComponent("workday.sqlite").path
        do {
            // Exactly the schema Workday 1.0 created.
            let db = try SQLiteDatabase(path: path)
            try db.execute("""
            PRAGMA journal_mode=WAL;
            CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE sessions (
                id TEXT PRIMARY KEY, start REAL NOT NULL, end REAL,
                state TEXT NOT NULL CHECK (state IN ('active','closed','interrupted')),
                checkpoint REAL NOT NULL, checkpoint_kind TEXT NOT NULL, detected_at REAL, tz TEXT NOT NULL,
                created_at REAL NOT NULL, updated_at REAL NOT NULL, CHECK (end IS NULL OR end > start));
            CREATE INDEX sessions_start ON sessions(start);
            CREATE TABLE events (id INTEGER PRIMARY KEY AUTOINCREMENT, at REAL NOT NULL, kind TEXT NOT NULL, session_id TEXT, detail TEXT NOT NULL DEFAULT '');
            CREATE TABLE notifications_sent (day TEXT NOT NULL, kind TEXT NOT NULL, sent_at REAL NOT NULL, PRIMARY KEY (day, kind));
            CREATE TABLE settings (id INTEGER PRIMARY KEY CHECK (id = 1), json TEXT NOT NULL);
            INSERT INTO meta VALUES ('schema_version', '1'), ('data_revision', '7');
            INSERT INTO sessions VALUES ('8E0B1C7E-6A55-4A3B-9B0C-1D2E3F405162', 800000000, 800003600, 'closed', 800003600, 'heartbeat', NULL, 'Europe/Amsterdam', 800003600, 800003600);
            INSERT INTO settings VALUES (1, '{"dailyGoalMinutes":420,"hasCompletedFirstLaunch":true}');
            INSERT INTO notifications_sent VALUES ('2026-11-01', 'goal', 800003600);
            """)
            db.close()
        }
        _ = try WorkStore.validate(databaseAt: path)  // a v1 file is a valid backup for v2
        let store = try WorkStore(path: path)
        #expect(store.meta("schema_version") == "2")
        #expect(SyncValidation.isDeviceID(store.deviceID))
        let sessions = try store.loadSessions()
        #expect(sessions.count == 1)
        #expect(sessions[0].ownerDevice == store.deviceID)
        #expect(sessions[0].end == Date(timeIntervalSinceReferenceDate: 800003600))
        #expect(store.loadSettings().dailyGoalMinutes == 420)
        #expect(try store.loadSyncVersions().isEmpty)
        #expect(store.dataRevision == 7)
        // Reopening is a no-op and keeps the device ID.
        let id = store.deviceID
        let again = try WorkStore(path: path)
        #expect(again.deviceID == id)
    }
}
