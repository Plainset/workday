import Foundation

/// Streak and summary statistics. All functions read totals through a closure so the
/// single time-accounting service (`WorkLedger`) remains the only source of totals.
public enum WorkStats {
    /// Consecutive days meeting the goal, ending today (or yesterday while today is still in progress).
    ///
    /// Rules (deterministic):
    /// - If today already meets the goal, today counts and the streak continues backwards.
    /// - If today does not (yet) meet the goal, today neither counts nor breaks the streak;
    ///   counting starts from yesterday.
    /// - Any completed past day below the goal ends the streak. Weekends count like any other day.
    /// - The *current* goal is applied to every historical day.
    public static func currentStreak(today: DayKey,
                                     goalSeconds: TimeInterval,
                                     earliestDay: DayKey?,
                                     calendar: Calendar,
                                     total: (DayKey) -> TimeInterval) -> Int {
        guard goalSeconds > 0, let earliest = earliestDay else { return 0 }
        var streak = 0
        var cursor = today
        if total(today) >= goalSeconds {
            streak = 1
        }
        cursor = today.adding(days: -1, calendar: calendar)
        var guardCount = 0
        while cursor >= earliest, guardCount < 100_000 {
            guard total(cursor) >= goalSeconds else { break }
            streak += 1
            cursor = cursor.adding(days: -1, calendar: calendar)
            guardCount += 1
        }
        return streak
    }

    public struct MonthSummary: Equatable, Sendable {
        public var totalSeconds: TimeInterval
        public var goalDays: Int
        public var workedDays: Int
        public var elapsedDays: Int
    }

    /// Minimal month summary: total, days that met the goal, days with any work.
    public static func monthSummary(month: MonthKey,
                                    today: DayKey,
                                    goalSeconds: TimeInterval,
                                    calendar: Calendar,
                                    total: (DayKey) -> TimeInterval) -> MonthSummary {
        var summary = MonthSummary(totalSeconds: 0, goalDays: 0, workedDays: 0, elapsedDays: 0)
        for day in month.days(calendar: calendar) {
            let t = total(day)
            summary.totalSeconds += t
            if t > 0 { summary.workedDays += 1 }
            if goalSeconds > 0, t >= goalSeconds { summary.goalDays += 1 }
            if day <= today { summary.elapsedDays += 1 }
        }
        return summary
    }
}

/// Kinds of local notifications. Each fires at most once per local day.
public enum ReminderKind: String, CaseIterable, Sendable {
    case goalReached = "goal"
    case startReminder = "start"
    case stopReminder = "stop"
}

/// Decides which notifications are due. Pure and deterministic so it can be unit tested.
public enum ReminderPlanner {
    /// How long after the chosen time a start reminder may still fire (e.g. after the Mac wakes).
    public static let startReminderWindowMinutes = 180

    public static func due(now: Date,
                           calendar: Calendar,
                           settings: WorkdaySettings,
                           todaySeconds: TimeInterval,
                           isRunning: Bool,
                           alreadySent: (ReminderKind) -> Bool) -> [ReminderKind] {
        var result: [ReminderKind] = []
        let minute = TimeMath.minuteOfDay(now, calendar: calendar)

        if settings.goalNotificationEnabled,
           todaySeconds >= settings.dailyGoalSeconds,
           !alreadySent(.goalReached) {
            result.append(.goalReached)
        }
        if settings.startReminderEnabled,
           !isRunning,
           todaySeconds < settings.dailyGoalSeconds,
           minute >= settings.startReminderMinutes,
           minute < settings.startReminderMinutes + startReminderWindowMinutes,
           !alreadySent(.startReminder) {
            result.append(.startReminder)
        }
        if settings.stopReminderEnabled,
           isRunning,
           minute >= settings.stopReminderMinutes,
           !alreadySent(.stopReminder) {
            result.append(.stopReminder)
        }
        return result
    }
}
