import Foundation

/// Lifecycle state of a recorded work interval.
public enum SessionState: String, Codable, Sendable {
    /// The timer is currently running for this session (end is open).
    case active
    /// A finished, confirmed interval.
    case closed
    /// The app/machine stopped while this session was active. The portion up to `checkpoint`
    /// is confirmed; the gap `checkpoint ..< detectedAt` is pending a user decision.
    case interrupted
}

/// What produced the most recent trustworthy "alive" checkpoint of an active session.
public enum CheckpointKind: String, Codable, Sendable {
    case start
    case heartbeat
    case sleep
    case wake
    case shutdown
    case resumed

    /// Human description used by the recovery UI.
    public var explanation: String {
        switch self {
        case .start: return "the moment the timer was started"
        case .heartbeat: return "Workday's last periodic check-in"
        case .sleep: return "your Mac going to sleep"
        case .wake: return "your Mac waking from sleep"
        case .shutdown: return "your Mac shutting down, restarting or logging out"
        case .resumed: return "the timer being resumed after a recovery"
        }
    }

    /// Whether the exact stop moment is known (shutdown is observed directly).
    public var isExactStop: Bool { self == .shutdown }
}

/// An authoritative, timestamped work interval. Totals are always derived from these.
public struct WorkSession: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID
    public var start: Date
    /// `nil` while active or interrupted.
    public var end: Date?
    public var state: SessionState
    /// Last instant the app reliably observed this session alive.
    public var checkpoint: Date
    public var checkpointKind: CheckpointKind
    /// For interrupted sessions: when the relaunch detected the interruption.
    public var detectedAt: Date?
    /// Time zone identifier in effect when the session was recorded (historical context).
    public var timeZoneID: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(),
                start: Date,
                end: Date?,
                state: SessionState,
                checkpoint: Date? = nil,
                checkpointKind: CheckpointKind = .start,
                detectedAt: Date? = nil,
                timeZoneID: String = TimeZone.current.identifier,
                createdAt: Date = Date(),
                updatedAt: Date = Date()) {
        self.id = id
        self.start = start
        self.end = end
        self.state = state
        self.checkpoint = checkpoint ?? end ?? start
        self.checkpointKind = checkpointKind
        self.detectedAt = detectedAt
        self.timeZoneID = timeZoneID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// End of the portion that counts as confirmed work at `now`.
    public func confirmedEnd(now: Date) -> Date {
        switch state {
        case .closed:
            return max(start, end ?? start)
        case .active:
            return max(start, now)
        case .interrupted:
            return max(start, min(checkpoint, detectedAt ?? checkpoint))
        }
    }

    /// Confirmed duration at `now`.
    public func confirmedDuration(now: Date) -> TimeInterval {
        confirmedEnd(now: now).timeIntervalSince(start)
    }

    /// The uncertain gap awaiting a recovery decision (interrupted sessions only).
    public var pendingGap: DateInterval? {
        guard state == .interrupted, let detected = detectedAt else { return nil }
        let gapStart = max(start, checkpoint)
        guard detected > gapStart else { return nil }
        return DateInterval(start: gapStart, end: detected)
    }

    /// End of the time range this session reserves for overlap checks.
    /// Active sessions reserve everything after their start; interrupted sessions reserve their pending gap.
    public var occupiedEnd: Date {
        switch state {
        case .closed: return end ?? start
        case .active: return .distantFuture
        case .interrupted: return max(checkpoint, detectedAt ?? checkpoint, start)
        }
    }

    public var isActive: Bool { state == .active }
    public var isInterrupted: Bool { state == .interrupted }
}
