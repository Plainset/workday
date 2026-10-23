import Foundation

/// User preferences persisted inside the database (so they are included in backups).
public struct WorkdaySettings: Codable, Equatable, Sendable {
    /// The single daily goal applied to every date, in minutes.
    public var dailyGoalMinutes: Int
    public var goalNotificationEnabled: Bool
    public var startReminderEnabled: Bool
    /// Minutes after local midnight.
    public var startReminderMinutes: Int
    public var stopReminderEnabled: Bool
    /// Minutes after local midnight.
    public var stopReminderMinutes: Int
    /// Set once the first-launch login-item registration has been attempted.
    public var launchAtLoginInitialized: Bool
    /// Set after the very first launch has shown the calendar once.
    public var hasCompletedFirstLaunch: Bool

    public static let minimumGoalMinutes = 15
    public static let maximumGoalMinutes = 24 * 60

    public init(dailyGoalMinutes: Int = 8 * 60,
                goalNotificationEnabled: Bool = true,
                startReminderEnabled: Bool = false,
                startReminderMinutes: Int = 9 * 60,
                stopReminderEnabled: Bool = false,
                stopReminderMinutes: Int = 18 * 60,
                launchAtLoginInitialized: Bool = false,
                hasCompletedFirstLaunch: Bool = false) {
        self.dailyGoalMinutes = dailyGoalMinutes
        self.goalNotificationEnabled = goalNotificationEnabled
        self.startReminderEnabled = startReminderEnabled
        self.startReminderMinutes = startReminderMinutes
        self.stopReminderEnabled = stopReminderEnabled
        self.stopReminderMinutes = stopReminderMinutes
        self.launchAtLoginInitialized = launchAtLoginInitialized
        self.hasCompletedFirstLaunch = hasCompletedFirstLaunch
    }

    public var dailyGoalSeconds: TimeInterval { TimeInterval(dailyGoalMinutes * 60) }

    /// Clamps values into valid ranges.
    public func normalized() -> WorkdaySettings {
        var s = self
        s.dailyGoalMinutes = min(max(s.dailyGoalMinutes, Self.minimumGoalMinutes), Self.maximumGoalMinutes)
        s.startReminderMinutes = min(max(s.startReminderMinutes, 0), 24 * 60 - 1)
        s.stopReminderMinutes = min(max(s.stopReminderMinutes, 0), 24 * 60 - 1)
        return s
    }

    // Tolerant decoding: missing keys fall back to defaults so older backups stay restorable.
    public init(from decoder: Decoder) throws {
        let d = WorkdaySettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dailyGoalMinutes = try c.decodeIfPresent(Int.self, forKey: .dailyGoalMinutes) ?? d.dailyGoalMinutes
        goalNotificationEnabled = try c.decodeIfPresent(Bool.self, forKey: .goalNotificationEnabled) ?? d.goalNotificationEnabled
        startReminderEnabled = try c.decodeIfPresent(Bool.self, forKey: .startReminderEnabled) ?? d.startReminderEnabled
        startReminderMinutes = try c.decodeIfPresent(Int.self, forKey: .startReminderMinutes) ?? d.startReminderMinutes
        stopReminderEnabled = try c.decodeIfPresent(Bool.self, forKey: .stopReminderEnabled) ?? d.stopReminderEnabled
        stopReminderMinutes = try c.decodeIfPresent(Int.self, forKey: .stopReminderMinutes) ?? d.stopReminderMinutes
        launchAtLoginInitialized = try c.decodeIfPresent(Bool.self, forKey: .launchAtLoginInitialized) ?? d.launchAtLoginInitialized
        hasCompletedFirstLaunch = try c.decodeIfPresent(Bool.self, forKey: .hasCompletedFirstLaunch) ?? d.hasCompletedFirstLaunch
    }
}
