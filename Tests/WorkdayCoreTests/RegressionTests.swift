import Foundation
import Testing
@testable import WorkdayCore

/// Regression tests for findings from independent review cycle 1 (see docs/review-ledger.md).
@MainActor
@Suite("Review cycle 1 regressions")
struct RegressionTests {
    func crashed(relaunchAt relaunch: Date) throws -> (WorkLedger, TestClock) {
        let (ledger, clock, dir) = try makeLedger(at: date(2026, 10, 23, 9, 0))
        try ledger.start()
        clock.now = date(2026, 10, 23, 11, 0)
        ledger.checkpoint(kind: .heartbeat)
        clock.now = relaunch
        let relaunched = try WorkLedger(store: try WorkStore(path: dir.appendingPathComponent("workday.sqlite").path),
                                        calendar: calendar(), clock: { clock.now })
        try relaunched.detectInterruptions()
        return (relaunched, clock)
    }

    @Test("F2: deciding late with 'resume from now' does not count the time since relaunch")
    func lateDecisionFromNow() throws {
        let (ledger, clock) = try crashed(relaunchAt: date(2026, 10, 23, 13, 0))
        clock.now = date(2026, 10, 23, 15, 0) // user clicked "Decide later", applies 2h later
        try ledger.resolveRecovery(sessionID: ledger.pendingRecoveries[0].id, decision: .excludeGap, continuation: .fromNow)
        clock.now = date(2026, 10, 23, 16, 0)
        #expect(ledger.total(for: ledger.today()) == 3 * 3600) // 09–11 + 15–16
        #expect(ledger.activeSession?.start == date(2026, 10, 23, 15, 0))
    }

    @Test("F2: 'resume from relaunch' explicitly counts relaunch → now")
    func lateDecisionFromRelaunch() throws {
        let (ledger, clock) = try crashed(relaunchAt: date(2026, 10, 23, 13, 0))
        clock.now = date(2026, 10, 23, 15, 0)
        let outcome = try ledger.recoveryOutcome(for: ledger.pendingRecoveries[0], decision: .excludeGap, continuation: .fromRelaunch)
        #expect(outcome.pieces.last?.start == date(2026, 10, 23, 13, 0))
        #expect(outcome.countedSeconds(now: clock.now) == 4 * 3600)
    }

    @Test("F4: stopping with the clock moved backwards keeps the session")
    func clockBackwardsStop() throws {
        let (ledger, clock, _) = try makeLedger(at: date(2026, 10, 23, 9, 0))
        try ledger.start()
        clock.now = date(2026, 10, 23, 8, 0)
        #expect(throws: LedgerError.clockWentBackwards) { try ledger.stop() }
        #expect(ledger.isRunning)
        clock.now = date(2026, 10, 23, 10, 0)
        try ledger.stop()
        #expect(ledger.total(for: ledger.today()) == 3600)
    }

    @Test("F4: relaunch with an earlier clock preserves the confirmed portion")
    func clockBackwardsRecovery() throws {
        let (ledger, _) = try crashed(relaunchAt: date(2026, 10, 23, 8, 0))
        let s = ledger.pendingRecoveries[0]
        #expect(s.detectedAt! >= s.checkpoint)
        #expect(ledger.total(for: ledger.today()) == 2 * 3600)
        try ledger.resolveRecovery(sessionID: s.id, decision: .excludeGap, continuation: .none)
        #expect(ledger.total(for: ledger.today()) == 2 * 3600)
    }

    @Test("F5: a manual session ending within the tolerance is clamped so Start still works")
    func manualEndClamped() throws {
        let (ledger, _, _) = try makeLedger(at: date(2026, 10, 23, 12, 0, 0))
        let s = try ledger.addSession(start: date(2026, 10, 23, 11, 0), end: date(2026, 10, 23, 12, 0, 40))
        #expect(s.end == date(2026, 10, 23, 12, 0, 0))
        try ledger.start()
        #expect(ledger.isRunning)
    }

    @Test("F7: last backup date ignores pre-restore safety copies")
    func lastBackupIgnoresSafety() throws {
        let (ledger, clock, dir) = try makeLedger(at: date(2026, 10, 23, 18, 0))
        let backups = BackupManager(store: ledger.store, directory: dir.appendingPathComponent("Backups"))
        let manual = try backups.createBackup(kind: .manual, now: clock.now)
        try backups.createBackup(kind: .safety, now: clock.now.addingTimeInterval(3600))
        #expect(backups.lastBackupDate == manual.createdAt)
    }

    @Test("F9: restoring an older backup does not re-arm today's goal notification")
    func restoreKeepsNotificationRecords() throws {
        let (ledger, clock, dir) = try makeLedger(at: date(2026, 10, 23, 18, 0))
        let backups = BackupManager(store: ledger.store, directory: dir.appendingPathComponent("Backups"))
        let old = try backups.createBackup(kind: .manual, now: clock.now)
        let today = ledger.today()
        try ledger.store.markNotified(day: today, kind: .goalReached, at: clock.now)
        try backups.restore(old, now: clock.now.addingTimeInterval(60))
        #expect(ledger.store.wasNotified(day: today, kind: .goalReached))
    }

    @Test("F10: check-in reminder only for a session already running at the chosen time")
    func checkInWindow() {
        let cal = calendar()
        var s = WorkdaySettings()
        s.goalNotificationEnabled = false
        s.stopReminderEnabled = true
        s.stopReminderMinutes = 18 * 60
        let lateStart = ReminderPlanner.due(now: date(2026, 10, 23, 22, 1), calendar: cal, settings: s, todaySeconds: 60,
                                            isRunning: true, activeSessionStart: date(2026, 10, 23, 22, 0)) { _ in false }
        #expect(lateStart.isEmpty)
        let forgot = ReminderPlanner.due(now: date(2026, 10, 23, 18, 1), calendar: cal, settings: s, todaySeconds: 60,
                                         isRunning: true, activeSessionStart: date(2026, 10, 23, 9, 0)) { _ in false }
        #expect(forgot == [.stopReminder])
    }

    @Test("F1: permission is requested when a notification feature is on and undecided — including the default")
    func permissionPolicy() {
        #expect(NotificationPermissionPolicy.shouldRequest(settings: WorkdaySettings(), permissionUndetermined: true))
        #expect(!NotificationPermissionPolicy.shouldRequest(settings: WorkdaySettings(), permissionUndetermined: false))
        var off = WorkdaySettings()
        off.goalNotificationEnabled = false
        #expect(!NotificationPermissionPolicy.shouldRequest(settings: off, permissionUndetermined: true))
    }
}

/// Regression tests for findings from independent review cycle 2.
@MainActor
@Suite("Review cycle 2 regressions")
struct Cycle2RegressionTests {
    @Test("F12: resuming is refused while the clock is behind the relaunch; resolving without resume works")
    func resumeWithClockBehind() throws {
        let (ledger, clock, dir) = try makeLedger(at: date(2026, 10, 23, 9, 0))
        try ledger.start()
        clock.now = date(2026, 10, 23, 11, 0)
        ledger.checkpoint(kind: .heartbeat)
        clock.now = date(2026, 10, 23, 8, 0) // clock moved back before relaunch
        let relaunched = try WorkLedger(store: try WorkStore(path: dir.appendingPathComponent("workday.sqlite").path),
                                        calendar: calendar(), clock: { clock.now })
        try relaunched.detectInterruptions()
        let s = relaunched.pendingRecoveries[0]
        #expect(throws: (any Error).self) { try relaunched.resolveRecovery(sessionID: s.id, decision: .excludeGap, continuation: .fromNow) }
        #expect(throws: (any Error).self) { try relaunched.resolveRecovery(sessionID: s.id, decision: .countGap, continuation: .fromRelaunch) }
        try relaunched.resolveRecovery(sessionID: s.id, decision: .excludeGap, continuation: .none)
        #expect(relaunched.total(for: DayKey(year: 2026, month: 10, day: 23)) == 2 * 3600)
    }

    @Test("F7 follow-up: pruning spares the newest valid backup when every kept file is corrupt")
    func pruneSparesValid() throws {
        let (ledger, clock, dir) = try makeLedger(at: date(2026, 10, 23, 18, 0))
        let backupDir = dir.appendingPathComponent("Backups")
        let backups = BackupManager(store: ledger.store, directory: backupDir)
        let good = try backups.createBackup(kind: .safety, now: clock.now)
        // 10 newer corrupt safety files fill the retention window.
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        for i in 1...10 {
            let url = backupDir.appendingPathComponent("workday-safety-\(f.string(from: clock.now.addingTimeInterval(TimeInterval(i * 60)))).sqlite")
            try Data("corrupt".utf8).write(to: url)
        }
        backups.prune()
        #expect(FileManager.default.fileExists(atPath: good.url.path))
    }

    @Test("U-a11y: day accessibility label contains the full date and exact hours")
    func accessibilityLabel() {
        var cal = calendar()
        cal.locale = Locale(identifier: "en_GB")
        let label = DayAccessibility.label(day: DayKey(year: 2026, month: 10, day: 23), seconds: 6 * 3600 + 35 * 60,
                                           pending: 0, isToday: true, live: true, metGoal: false, calendar: cal)
        #expect(label.contains("23 October 2026"))
        #expect(label.contains("Friday"))
        #expect(label.contains("6 hours 35 minutes worked"))
        #expect(label.hasPrefix("Today"))
        #expect(label.contains("timer running"))
        let big = DayAccessibility.label(day: DayKey(year: 2026, month: 10, day: 7), seconds: 19 * 3600, pending: 1800,
                                         isToday: false, live: false, metGoal: true, calendar: cal)
        #expect(big.contains("19 hours worked") && big.contains("goal met") && big.contains("more than 18 hours")
                && big.contains("30 minutes pending review"))
    }
}

/// Regression tests for findings from independent review cycle 4.
@Suite("Review cycle 4 regressions")
struct Cycle4RegressionTests {
    final class Wall { var now: Double = 1_000_000 }

    @Test("P1: a data change while the liquid is holding a still frame animates to the new level")
    func staleFrameTimeStillAnimates() {
        let wall = Wall()
        let motion = LiquidMotion(wallClock: { wall.now })
        let key = DayKey(year: 2026, month: 10, day: 23)
        // Layer appears and pours in to 20 %, then the user leaves it alone; frames stop.
        let frameTime = wall.now
        _ = motion.fraction(for: key, target: 0.2, t: frameTime, animated: true)
        wall.now += LiquidMotion.idleDriftDuration + LiquidMotion.calmDownDuration + 60
        #expect(!motion.isSettling(t: wall.now))
        #expect(motion.fraction(for: key, target: 0.2, t: wall.now, animated: true) == 0.2)
        // An edit raises the day to 40 %; SwiftUI redraws with the stale frame time.
        let staleDraw = motion.fraction(for: key, target: 0.4, t: frameTime, animated: true)
        #expect(staleDraw == 0.2)                           // still the old level on that redraw…
        #expect(motion.isSettling(t: wall.now))             // …but the loop sees motion and produces frames
        let settled = motion.fraction(for: key, target: 0.4, t: wall.now + LiquidMotion.fillDuration, animated: true)
        #expect(settled == 0.4)                             // and the liquid reaches the new level
        #expect(motion.energy(for: key, t: wall.now) > 0.9) // with a fresh slosh, not a stale one
    }

    @Test("Calm eases to a still surface after the drift period and ramps back on interaction")
    func calmCurve() {
        let wall = Wall()
        let motion = LiquidMotion(wallClock: { wall.now })
        let start = wall.now
        #expect(motion.calm(t: start + 10) == 1)
        #expect(motion.calm(t: start + LiquidMotion.idleDriftDuration + LiquidMotion.calmDownDuration + 0.1) == 0)
        let wake = start + 100
        motion.touch(t: wake)
        #expect(motion.calm(t: wake) == 0)
        #expect(motion.calm(t: wake + LiquidMotion.wakeDuration / 2) > 0.4)
        #expect(motion.calm(t: wake + LiquidMotion.wakeDuration) == 1)
    }
}

@Suite("Review cycle 5 regressions")
struct Cycle5RegressionTests {
    final class Wall { var now: Double = 2_000_000 }

    @Test("Q1: a transition created at S is never drawn with an earlier (stale) frame time")
    func crossLayerStaleDraw() {
        let wall = Wall()
        let motion = LiquidMotion(wallClock: { wall.now })
        let key = DayKey(year: 2026, month: 10, day: 24)
        _ = motion.fraction(for: key, target: 0.2, t: wall.now, animated: true)
        wall.now += 100
        // Live layer (fresh frame time) records a change to 0.5 at S = now.
        _ = motion.fraction(for: key, target: 0.5, t: wall.now, animated: true)
        wall.now += LiquidMotion.fillDuration + 5
        // The day moves to a still layer whose last frame time predates S; same target.
        let staleT = wall.now - 200
        #expect(motion.fraction(for: key, target: 0.5, t: staleT, animated: true) == 0.5)
    }
}

@MainActor
@Suite("Open-source release hardening")
struct ReleaseHardeningTests {
    @Test("Database, data directory and backups are owner-only")
    func ownerOnlyPermissions() throws {
        let dir = tempDir().appendingPathComponent("data")
        try OwnerOnly.createDirectory(at: dir)
        let store = try WorkStore(path: dir.appendingPathComponent("workday.sqlite").path)
        let perms = { (path: String) in (try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue ?? -1 }
        #expect(try perms(dir.path) == 0o700)
        #expect(try perms(dir.appendingPathComponent("workday.sqlite").path) == 0o600)
        let backups = BackupManager(store: store, directory: dir.appendingPathComponent("Backups"))
        let b = try backups.createBackup(kind: .manual)
        #expect(try perms(dir.appendingPathComponent("Backups").path) == 0o700)
        #expect(try perms(b.url.path) == 0o600)
    }

    @Test("A v1 database reopens with all sessions and settings intact (upgrade path)")
    func v1DatabaseReopens() throws {
        let (ledger, _, dir) = try makeLedger(at: date(2026, 10, 23, 18, 0))
        try ledger.addSession(start: date(2026, 10, 20, 9), end: date(2026, 10, 20, 17))
        try ledger.addSession(start: date(2026, 10, 21, 23, 30), end: date(2026, 10, 22, 1, 15))
        try ledger.updateSettings { $0.dailyGoalMinutes = 7 * 60 + 30 }
        let before = ledger.sessions
        let path = dir.appendingPathComponent("workday.sqlite").path
        let reopened = try WorkStore(path: path)
        #expect(reopened.meta("schema_version") == String(WorkStore.schemaVersion))
        #expect(try reopened.loadSessions() == before)
        #expect(reopened.loadSettings().dailyGoalMinutes == 7 * 60 + 30)
    }

    @Test("A database from a newer schema is refused, not downgraded")
    func newerSchemaRefused() throws {
        let path = tempDir().appendingPathComponent("w.sqlite").path
        let store = try WorkStore(path: path)
        try store.setMeta("schema_version", String(WorkStore.schemaVersion + 1))
        #expect(throws: StoreError.newerSchema(WorkStore.schemaVersion + 1)) { _ = try WorkStore(path: path) }
        #expect(store.meta("schema_version") == String(WorkStore.schemaVersion + 1))
    }

    @Test("Backups and lock created by an older version are tightened to owner-only")
    func upgradeTightensExistingFiles() throws {
        let dir = tempDir()
        let backupsDir = dir.appendingPathComponent("Backups")
        try FileManager.default.createDirectory(at: backupsDir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        let old = backupsDir.appendingPathComponent("workday-auto-20261001T000000Z.sqlite")
        FileManager.default.createFile(atPath: old.path, contents: Data(), attributes: [.posixPermissions: 0o644])
        let store = try WorkStore(path: dir.appendingPathComponent("w.sqlite").path)
        BackupManager(store: store, directory: backupsDir).tightenPermissions()
        let perms = { (path: String) in (try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue ?? -1 }
        #expect(try perms(backupsDir.path) == 0o700)
        #expect(try perms(old.path) == 0o600)
        let lockURL = dir.appendingPathComponent(".lock")
        let lock = SingleInstanceLock(url: lockURL)
        #expect(lock != nil)
        #expect(try perms(lockURL.path) == 0o600)
    }
}
