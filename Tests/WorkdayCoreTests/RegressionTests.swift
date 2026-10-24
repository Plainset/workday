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
