import AppKit
import SwiftUI
import WorkdayCore

/// App-wide state shared by the menu bar, calendar, editor and settings.
/// All time figures come from the single `WorkLedger`.
@MainActor
@Observable
final class AppModel {
    let ledger: WorkLedger
    let backups: BackupManager
    let notifications: NotificationService
    let launchAtLogin: LaunchAtLogin

    /// Display clock, refreshed by `tick()`. Totals never depend on tick frequency; they are computed
    /// from stored instants and this value.
    var now: Date
    /// Minute-resolution clock for the calendar and editor (they display whole minutes), so those
    /// views re-render at most once a minute instead of every second.
    private(set) var displayNow: Date

    /// User-visible error banner (e.g. a failed save or backup).
    var errorMessage: String?
    var backupStatus: BackupStatus = .unknown
    /// Whether the calendar window is currently on screen (drives animation pausing).
    var calendarVisible = false
    /// Whether the menu bar popover is open (its liquid glass pauses when closed).
    var popoverVisible = false
    /// Set when the user explicitly opens a day from somewhere else (e.g. the menu).
    var requestedDay: DayKey?

    enum BackupStatus: Equatable {
        case unknown
        case ok(Date)
        case none
        case failed(String)
    }

    init(ledger: WorkLedger, backups: BackupManager, notifications: NotificationService, launchAtLogin: LaunchAtLogin) {
        self.ledger = ledger
        self.backups = backups
        self.notifications = notifications
        self.launchAtLogin = launchAtLogin
        self.now = ledger.clock()
        self.displayNow = Self.minuteFloor(ledger.clock())
        refreshBackupStatus()
    }

    var calendar: Calendar { ledger.calendar }
    var today: DayKey { ledger.today(now: displayNow) }
    /// Today's total and goal progress at minute resolution (calendar use).
    var displayTodayTotal: TimeInterval { ledger.total(for: today, now: displayNow) }
    var displayGoalProgress: Double { goalSeconds > 0 ? displayTodayTotal / goalSeconds : 0 }
    var todayTotal: TimeInterval { ledger.total(for: ledger.today(now: now), now: now) }
    var goalSeconds: TimeInterval { ledger.settings.dailyGoalSeconds }
    var goalProgress: Double { goalSeconds > 0 ? todayTotal / goalSeconds : 0 }
    var isRunning: Bool { ledger.isRunning }

    // MARK: Timer actions

    func start() {
        perform { try ledger.start() }
        AppDelegate.shared?.timerStateChanged()
    }

    func stop() {
        perform { try ledger.stop() }
        AppDelegate.shared?.timerStateChanged()
    }

    /// Advances the display clocks. `now` changes every second only while the popover (which shows
    /// seconds) is open; otherwise both clocks change once a minute, so idle views don't re-render.
    func tick(_ date: Date = Date()) {
        let minute = Self.minuteFloor(date)
        if popoverVisible || minute != displayNow { now = date }
        if minute != displayNow { displayNow = minute }
    }

    private static func minuteFloor(_ date: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60)
    }

    /// Runs a ledger mutation, surfacing any error to the user.
    @discardableResult
    func perform(_ body: () throws -> Void) -> Bool {
        do {
            try body()
            tick(ledger.clock())
            displayNow = ledger.clock()
            errorMessage = nil
            AppDelegate.shared?.timerStateChanged()
            return true
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

    // MARK: Backups

    func refreshBackupStatus() {
        if let error = backups.lastError {
            backupStatus = .failed(error)
        } else if let date = backups.lastBackupDate {
            backupStatus = .ok(date)
        } else {
            backupStatus = .none
        }
    }

    func runAutomaticBackup() {
        do {
            try backups.performAutomaticBackupIfNeeded(now: Date(), calendar: calendar)
        } catch {
            // Status shows the failure; tracking continues regardless.
        }
        refreshBackupStatus()
    }

    func backupNow() -> Bool {
        defer { refreshBackupStatus() }
        do {
            try backups.createBackup(kind: .manual)
            return true
        } catch {
            errorMessage = "Backup failed: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
            return false
        }
    }

    func restore(_ backup: BackupInfo) -> Bool {
        if ledger.isRunning {
            errorMessage = "Stop the timer before restoring a backup."
            return false
        }
        do {
            try backups.restore(backup)
            try ledger.reload()
            // A restored snapshot may contain a session that was running when it was taken.
            let found = try ledger.detectInterruptions()
            now = ledger.clock()
            refreshBackupStatus()
            errorMessage = nil
            if !found.isEmpty || ledger.hasPendingRecovery { AppDelegate.shared?.showRecovery() }
            AppDelegate.shared?.timerStateChanged()
            return true
        } catch {
            try? ledger.reload()
            errorMessage = "Restore failed; your current data was kept. \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
            refreshBackupStatus()
            return false
        }
    }

    // MARK: Notifications

    /// Posts any due notifications exactly once per local day.
    func evaluateReminders() {
        let today = self.today
        let total = todayTotal
        let due = ReminderPlanner.due(now: now, calendar: calendar, settings: ledger.settings, todaySeconds: total,
                                      isRunning: isRunning, activeSessionStart: ledger.activeSession?.start) { kind in
            ledger.store.wasNotified(day: today, kind: kind)
        }
        guard !due.isEmpty else { return }
        guard notifications.permission == .authorized else { return }
        for kind in due {
            guard (try? ledger.store.markNotified(day: today, kind: kind, at: now)) == true else { continue }
            switch kind {
            case .goalReached:
                notifications.post(id: "goal-\(today)", title: "Daily goal reached",
                                   body: "You've worked \(DurationFormat.short(total)) today — goal of \(DurationFormat.goal(minutes: ledger.settings.dailyGoalMinutes)) met.")
            case .startReminder:
                notifications.post(id: "start-\(today)", title: "Ready to start work?",
                                   body: "Your Workday timer isn't running. Click the Workday menu bar item to start.")
            case .stopReminder:
                notifications.post(id: "stop-\(today)", title: "Workday timer is still running",
                                   body: "Today: \(DurationFormat.short(total)). Stop the timer if you've finished.")
            }
        }
    }

    /// Asks for permission once if any notification feature (the goal notice is on by default) is enabled
    /// and the user hasn't decided yet.
    func requestNotificationPermissionIfNeeded() async {
        await notifications.refresh()
        if NotificationPermissionPolicy.shouldRequest(settings: ledger.settings,
                                                      permissionUndetermined: notifications.permission == .notDetermined) {
            await notifications.requestAuthorization()
        }
    }

    /// Enables a notification preference, requesting permission the first time.
    func enableNotificationFeature(_ change: @escaping (inout WorkdaySettings) -> Void) {
        perform { try ledger.updateSettings(change) }
        Task { await requestNotificationPermissionIfNeeded() }
    }
}
