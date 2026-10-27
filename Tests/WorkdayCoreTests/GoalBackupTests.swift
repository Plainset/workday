import Foundation
import Testing
@testable import WorkdayCore

@MainActor
@Suite("Goals, streaks and reminders (A10)")
struct GoalTests {
    @Test("Goal changes progress; streak rules are deterministic")
    func streaks() throws {
        let (ledger, clock, _) = try makeLedger(at: date(2026, 10, 23, 10, 0))
        // 19, 20, 21, 22 Oct: 8h, 8h, 5h, 9h
        try ledger.addSession(start: date(2026, 10, 19, 9), end: date(2026, 10, 19, 17))
        try ledger.addSession(start: date(2026, 10, 20, 9), end: date(2026, 10, 20, 17))
        try ledger.addSession(start: date(2026, 10, 21, 9), end: date(2026, 10, 21, 14))
        try ledger.addSession(start: date(2026, 10, 22, 9), end: date(2026, 10, 22, 18))
        // Today is in progress with 0h: it doesn't break the streak.
        #expect(ledger.streak() == 1)
        try ledger.updateSettings { $0.dailyGoalMinutes = 5 * 60 }
        #expect(ledger.streak() == 4)          // current goal applied to history
        try ledger.updateSettings { $0.dailyGoalMinutes = 8 * 60 }
        #expect(ledger.goalProgress() == 0)
        try ledger.start()
        clock.advance(4 * 3600)
        #expect(ledger.goalProgress() == 0.5)
        clock.advance(4 * 3600)
        #expect(ledger.streak() == 2)          // today reached: counts
        try ledger.updateSettings { $0.dailyGoalMinutes = 16 * 60 }
        #expect(ledger.goalProgress() == 0.5)
        let summary = ledger.monthSummary(MonthKey(year: 2026, month: 10))
        #expect(summary.totalSeconds == 38 * 3600)
        #expect(summary.goalDays == 0)
        #expect(summary.workedDays == 5)
    }

    @Test("This week: current calendar week from the first weekday, including the live session")
    func weekTotal() throws {
        // Friday 23 Oct 2026; Monday-first calendar → week is Mon 19 – Sun 25 Oct.
        let (ledger, clock, _) = try makeLedger(at: date(2026, 10, 23, 10, 0))
        try ledger.addSession(start: date(2026, 10, 18, 9), end: date(2026, 10, 18, 17))      // Sun before: excluded
        try ledger.addSession(start: date(2026, 10, 19, 9), end: date(2026, 10, 19, 12))      // Mon: 3h
        try ledger.addSession(start: date(2026, 10, 18, 23), end: date(2026, 10, 19, 1))      // crosses into Mon: +1h
        try ledger.addSession(start: date(2026, 10, 22, 9), end: date(2026, 10, 22, 11))      // Thu: 2h
        try ledger.start()
        clock.advance(3600)                                                                   // live: 1h today
        #expect(ledger.weekTotal() == 7 * 3600)
        #expect(MonthGridLayout.week(containing: DayKey(year: 2026, month: 10, day: 23), calendar: calendar()).first
                == DayKey(year: 2026, month: 10, day: 19))
        var sundayFirst = calendar()
        sundayFirst.firstWeekday = 1
        #expect(MonthGridLayout.week(containing: DayKey(year: 2026, month: 10, day: 23), calendar: sundayFirst).first
                == DayKey(year: 2026, month: 10, day: 18))
    }

    @Test("Missed completed day breaks the streak; settings persist and are clamped")
    func streakBreak() throws {
        let (ledger, _, dir) = try makeLedger(at: date(2026, 10, 23, 10, 0))
        try ledger.addSession(start: date(2026, 10, 20, 9), end: date(2026, 10, 20, 17))
        try ledger.addSession(start: date(2026, 10, 22, 9), end: date(2026, 10, 22, 17))
        #expect(ledger.streak() == 1)
        try ledger.updateSettings { $0.dailyGoalMinutes = 1 }
        #expect(ledger.settings.dailyGoalMinutes == WorkdaySettings.minimumGoalMinutes)
        let reopened = try WorkStore(path: dir.appendingPathComponent("workday.sqlite").path)
        #expect(reopened.loadSettings().dailyGoalMinutes == WorkdaySettings.minimumGoalMinutes)
    }

    @Test("Goal notification fires once per day; reminders respect preferences and windows")
    func reminders() throws {
        let cal = calendar()
        var s = WorkdaySettings()
        var sent: Set<ReminderKind> = []
        func due(_ now: Date, _ total: TimeInterval, running: Bool) -> [ReminderKind] {
            ReminderPlanner.due(now: now, calendar: cal, settings: s, todaySeconds: total, isRunning: running) { sent.contains($0) }
        }
        #expect(due(date(2026, 10, 23, 15), 7 * 3600, running: true).isEmpty)
        #expect(due(date(2026, 10, 23, 16), 8 * 3600, running: true) == [.goalReached])
        sent.insert(.goalReached)
        #expect(due(date(2026, 10, 23, 16, 1), 8 * 3600 + 60, running: true).isEmpty)
        s.goalNotificationEnabled = false
        sent = []
        #expect(due(date(2026, 10, 23, 16), 9 * 3600, running: true).isEmpty)

        s.startReminderEnabled = true
        s.startReminderMinutes = 9 * 60
        #expect(due(date(2026, 10, 23, 8, 59), 0, running: false).isEmpty)
        #expect(due(date(2026, 10, 23, 9, 0), 0, running: false) == [.startReminder])
        #expect(due(date(2026, 10, 23, 9, 0), 0, running: true).isEmpty)
        #expect(due(date(2026, 10, 23, 13, 0), 0, running: false).isEmpty) // outside window
        s.startReminderEnabled = false

        s.stopReminderEnabled = true
        s.stopReminderMinutes = 18 * 60
        #expect(due(date(2026, 10, 23, 18, 5), 3600, running: false).isEmpty)
        #expect(due(date(2026, 10, 23, 18, 5), 3600, running: true) == [.stopReminder])
        sent.insert(.stopReminder)
        #expect(due(date(2026, 10, 23, 19, 5), 3600, running: true).isEmpty)
    }

    @Test("Notification bookkeeping is durable and once-per-day")
    func notificationStore() throws {
        let dir = tempDir()
        let store = try WorkStore(path: dir.appendingPathComponent("w.sqlite").path)
        let day = DayKey(year: 2026, month: 10, day: 23)
        #expect(try store.markNotified(day: day, kind: .goalReached, at: Date()))
        #expect(try store.markNotified(day: day, kind: .goalReached, at: Date()) == false)
        let reopened = try WorkStore(path: dir.appendingPathComponent("w.sqlite").path)
        #expect(reopened.wasNotified(day: day, kind: .goalReached))
        #expect(!reopened.wasNotified(day: day.adding(days: 1, calendar: calendar()), kind: .goalReached))
    }
}

@MainActor
@Suite("Backups (A11)")
struct BackupTests {
    @Test("Automatic snapshot is created daily only when data changed, and restore round-trips")
    func backupAndRestore() throws {
        let (ledger, clock, dir) = try makeLedger(at: date(2026, 10, 23, 18, 0))
        let backups = BackupManager(store: ledger.store, directory: dir.appendingPathComponent("Backups"))
        try ledger.addSession(start: date(2026, 10, 20, 9), end: date(2026, 10, 20, 17))
        try ledger.updateSettings { $0.dailyGoalMinutes = 7 * 60 }
        let first = try backups.performAutomaticBackupIfNeeded(now: clock.now, calendar: calendar())
        #expect(first != nil)
        #expect(try backups.performAutomaticBackupIfNeeded(now: clock.now, calendar: calendar()) == nil) // no change
        try ledger.addSession(start: date(2026, 10, 21, 9), end: date(2026, 10, 21, 10))
        #expect(try backups.performAutomaticBackupIfNeeded(now: clock.now.addingTimeInterval(60), calendar: calendar()) == nil) // same day
        #expect(try backups.performAutomaticBackupIfNeeded(now: clock.now.addingTimeInterval(86_400), calendar: calendar()) != nil) // next day

        // Damage current data, then restore the first snapshot.
        try ledger.deleteSession(id: ledger.sessions[0].id)
        try ledger.updateSettings { $0.dailyGoalMinutes = 3 * 60 }
        let list = backups.list()
        #expect(list.count == 2)
        #expect(list.allSatisfy { $0.isValid })
        let target = list.last!
        let safety = try backups.restore(target, now: clock.now.addingTimeInterval(200_000))
        #expect(safety.kind == .safety)
        try ledger.reload()
        #expect(ledger.total(for: DayKey(year: 2026, month: 10, day: 20)) == 8 * 3600)
        #expect(ledger.total(for: DayKey(year: 2026, month: 10, day: 21)) == 0)
        #expect(ledger.settings.dailyGoalMinutes == 7 * 60)
        // Safety copy holds the pre-restore state.
        let safetyStore = try WorkStore(path: safety.url.path)
        #expect(safetyStore.loadSettings().dailyGoalMinutes == 3 * 60)
        // The live database still works after restore.
        try ledger.addSession(start: date(2026, 10, 22, 9), end: date(2026, 10, 22, 10))
        #expect(ledger.total(for: DayKey(year: 2026, month: 10, day: 22)) == 3600)
    }

    @Test("Corrupted and partial backups are rejected; current data untouched")
    func corruptBackup() throws {
        let (ledger, clock, dir) = try makeLedger(at: date(2026, 10, 23, 18, 0))
        let backupDir = dir.appendingPathComponent("Backups")
        let backups = BackupManager(store: ledger.store, directory: backupDir)
        try ledger.addSession(start: date(2026, 10, 20, 9), end: date(2026, 10, 20, 17))
        let good = try backups.createBackup(kind: .manual, now: clock.now)
        // Truncate a copy to simulate a partial file.
        let bad = backupDir.appendingPathComponent("workday-manual-20261022T100000Z.sqlite")
        let data = try Data(contentsOf: good.url)
        try data.prefix(1024).write(to: bad)
        let garbage = backupDir.appendingPathComponent("workday-auto-20261021T100000Z.sqlite")
        try Data("not a database".utf8).write(to: garbage)
        let list = backups.list()
        #expect(list.count == 3)
        let invalid = list.filter { !$0.isValid }
        #expect(invalid.count == 2)
        for b in invalid {
            #expect(throws: (any Error).self) { try backups.restore(b) }
        }
        try ledger.reload()
        #expect(ledger.total(for: DayKey(year: 2026, month: 10, day: 20)) == 8 * 3600)
    }

    @Test("Backups include unresolved recovery state; restore then re-detects nothing extra")
    func recoveryInBackup() throws {
        let (ledger, clock, dir) = try makeLedger(at: date(2026, 10, 23, 9, 0))
        try ledger.start()
        clock.advance(3600)
        ledger.checkpoint(kind: .heartbeat)
        try ledger.detectInterruptions(launchTime: clock.now.addingTimeInterval(600))
        let backups = BackupManager(store: ledger.store, directory: dir.appendingPathComponent("Backups"))
        let b = try backups.createBackup(kind: .manual, now: clock.now)
        try ledger.resolveRecovery(sessionID: ledger.pendingRecoveries[0].id, decision: .excludeGap, continuation: .none)
        #expect(!ledger.hasPendingRecovery)
        try backups.restore(b, now: clock.now.addingTimeInterval(5))
        try ledger.reload()
        #expect(ledger.hasPendingRecovery)
    }

    @Test("Retention keeps the newest 30 automatic snapshots")
    func retention() throws {
        let (ledger, clock, dir) = try makeLedger(at: date(2026, 10, 23, 18, 0))
        let backups = BackupManager(store: ledger.store, directory: dir.appendingPathComponent("Backups"))
        for i in 0..<33 {
            try backups.createBackup(kind: .automatic, now: clock.now.addingTimeInterval(TimeInterval(i * 86_400)))
        }
        #expect(backups.list(validate: false).filter { $0.kind == .automatic }.count == 30)
    }
}
