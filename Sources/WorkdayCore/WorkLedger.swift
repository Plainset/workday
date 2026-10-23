import Foundation
import Observation

/// Validation and state errors with actionable, user-facing explanations.
public enum LedgerError: LocalizedError, Equatable {
    case endNotAfterStart
    case tooShort
    case inFuture
    case overlaps(description: String)
    case sessionRunning
    case sessionNotFound
    case notInterrupted
    case invalidRecovery(String)
    case recoveryPendingForSession
    case storage(String)
    case clockWentBackwards

    public var errorDescription: String? {
        switch self {
        case .endNotAfterStart:
            return "The end time must be after the start time."
        case .tooShort:
            return "A session must last at least one minute."
        case .inFuture:
            return "The end time is in the future. Sessions can only record time that has already happened — use Start for ongoing work."
        case .overlaps(let d):
            return "This overlaps \(d). Adjust the times so sessions don't overlap."
        case .sessionRunning:
            return "This session is still running. Stop the timer first, then edit it."
        case .sessionNotFound:
            return "That session no longer exists. It may have been changed elsewhere."
        case .notInterrupted:
            return "This interruption has already been resolved."
        case .invalidRecovery(let m):
            return m
        case .recoveryPendingForSession:
            return "This session was interrupted and needs a recovery decision before it can be edited."
        case .storage(let m):
            return "The change could not be saved: \(m)"
        case .clockWentBackwards:
            return "Your Mac's clock is now earlier than when this session started, so it can't be stopped safely. Check Date & Time in System Settings, then stop the timer again. Nothing has been lost."
        }
    }
}

/// How the user resolves an interrupted session.
public enum RecoveryDecision: Equatable, Sendable {
    /// Count everything from the original start through the relaunch.
    case countGap
    /// Count only up to the last reliable checkpoint.
    case excludeGap
    /// The user states when they actually stopped, and optionally when they resumed before the relaunch.
    case custom(end: Date, resumedAt: Date?)
}

/// Whether (and from when) the timer keeps running after a recovery decision.
public enum RecoveryContinuation: Equatable, Sendable {
    case none
    /// Continue as if Workday had been timing since the relaunch (counts relaunch → now).
    case fromRelaunch
    /// Start a fresh interval at the moment the decision is applied.
    case fromNow
}

/// The resulting intervals of a recovery decision (used for preview and for applying).
public struct RecoveryOutcome: Equatable, Sendable {
    public struct Piece: Equatable, Sendable {
        public var start: Date
        /// `nil` means the timer keeps running from `start`.
        public var end: Date?
    }
    public var pieces: [Piece]

    public func countedSeconds(now: Date) -> TimeInterval {
        pieces.reduce(0) { $0 + max(0, ($1.end ?? now).timeIntervalSince($1.start)) }
    }
}

/// The single time-accounting service. Menu bar, calendar, editor, statistics and notifications all
/// read totals from here. Sessions are authoritative timestamped intervals; per-day totals are derived
/// by splitting intervals at local midnight. The live session is computed from its recorded start
/// through `now` — UI refresh ticks never accrue time.
@MainActor
@Observable
public final class WorkLedger {
    public private(set) var sessions: [WorkSession] = []
    public private(set) var settings: WorkdaySettings
    /// Increments on every data change; views can key animations off it.
    public private(set) var revision: Int = 0

    /// Confirmed totals of all non-active sessions (closed + confirmed parts of interrupted ones).
    @ObservationIgnored private var settledTotals: [DayKey: TimeInterval] = [:]
    /// Pending (unresolved) gap seconds per day.
    @ObservationIgnored private var pendingTotals: [DayKey: TimeInterval] = [:]

    public private(set) var calendar: Calendar
    @ObservationIgnored public let store: WorkStore
    @ObservationIgnored public var clock: () -> Date

    /// Minimum duration of a manually entered session.
    public static let minimumManualSeconds: TimeInterval = 60
    /// Tolerance for "future" checks when editing with minute-precision pickers.
    public static let futureTolerance: TimeInterval = 60

    public init(store: WorkStore, calendar: Calendar = .autoupdatingCurrent, clock: @escaping () -> Date = Date.init) throws {
        self.store = store
        self.calendar = calendar
        self.clock = clock
        self.settings = store.loadSettings()
        try reload()
    }

    // MARK: Loading & caches

    public func reload() throws {
        sessions = try store.loadSessions()
        settings = store.loadSettings()
        rebuildCaches()
    }

    /// Call when the system time zone or calendar changes.
    public func setCalendar(_ calendar: Calendar) {
        self.calendar = calendar
        rebuildCaches()
    }

    private func rebuildCaches() {
        sessions.sort { $0.start < $1.start }
        var settled: [(start: Date, end: Date)] = []
        var pending: [(start: Date, end: Date)] = []
        for s in sessions where s.state != .active {
            let e = s.confirmedEnd(now: s.start)
            if e > s.start { settled.append((s.start, e)) }
            if let gap = s.pendingGap { pending.append((gap.start, gap.end)) }
        }
        settledTotals = TimeMath.dailyTotals(settled, calendar: calendar)
        pendingTotals = TimeMath.dailyTotals(pending, calendar: calendar)
        revision += 1
    }

    // MARK: Queries (the single source of totals)

    public var activeSession: WorkSession? { sessions.first { $0.state == .active } }
    public var isRunning: Bool { activeSession != nil }
    public var pendingRecoveries: [WorkSession] { sessions.filter { $0.state == .interrupted } }
    public var hasPendingRecovery: Bool { sessions.contains { $0.state == .interrupted } }

    public func today(now: Date? = nil) -> DayKey { DayKey(now ?? clock(), calendar: calendar) }

    /// Confirmed seconds worked on `day`, including the live portion of a running session.
    public func total(for day: DayKey, now: Date? = nil) -> TimeInterval {
        let now = now ?? clock()
        var t = settledTotals[day] ?? 0
        if let active = activeSession, now > active.start {
            t += TimeMath.seconds(of: active.start, now, on: day, calendar: calendar)
        }
        return t
    }

    /// Pending (unresolved recovery gap) seconds on `day`. Never included in `total`.
    public func pendingSeconds(for day: DayKey) -> TimeInterval { pendingTotals[day] ?? 0 }

    public func totals(for days: [DayKey], now: Date? = nil) -> [DayKey: TimeInterval] {
        let now = now ?? clock()
        var result: [DayKey: TimeInterval] = [:]
        for d in days { result[d] = total(for: d, now: now) }
        return result
    }

    /// Elapsed time of the running session.
    public func activeElapsed(now: Date? = nil) -> TimeInterval {
        guard let a = activeSession else { return 0 }
        return max(0, (now ?? clock()).timeIntervalSince(a.start))
    }

    /// Sessions with any confirmed or pending time on `day`, chronologically.
    public func sessions(touching day: DayKey, now: Date? = nil) -> [WorkSession] {
        let now = now ?? clock()
        let dayStart = day.startDate(in: calendar)
        let dayEnd = day.endDate(in: calendar)
        return sessions.filter { s in
            let end = s.state == .interrupted ? s.occupiedEnd : s.confirmedEnd(now: now)
            return s.start < dayEnd && (end > dayStart || (s.start >= dayStart && s.start < dayEnd))
        }
    }

    /// Confirmed seconds of `session` that fall on `day`.
    public func portion(of session: WorkSession, on day: DayKey, now: Date? = nil) -> TimeInterval {
        TimeMath.seconds(of: session.start, session.confirmedEnd(now: now ?? clock()), on: day, calendar: calendar)
    }

    public var earliestDay: DayKey? { sessions.first.map { DayKey($0.start, calendar: calendar) } }

    public func streak(now: Date? = nil) -> Int {
        let now = now ?? clock()
        return WorkStats.currentStreak(today: today(now: now), goalSeconds: settings.dailyGoalSeconds,
                                       earliestDay: earliestDay, calendar: calendar) { total(for: $0, now: now) }
    }

    public func monthSummary(_ month: MonthKey, now: Date? = nil) -> WorkStats.MonthSummary {
        let now = now ?? clock()
        return WorkStats.monthSummary(month: month, today: today(now: now), goalSeconds: settings.dailyGoalSeconds,
                                      calendar: calendar) { total(for: $0, now: now) }
    }

    public func goalProgress(now: Date? = nil) -> Double {
        let goal = settings.dailyGoalSeconds
        guard goal > 0 else { return 0 }
        return total(for: today(now: now), now: now) / goal
    }

    // MARK: Timer

    /// Starts the timer. Idempotent: if already running, returns the running session unchanged.
    @discardableResult
    public func start() throws -> WorkSession {
        if let active = activeSession { return active }
        let now = clock()
        if let conflict = conflicting(start: now, end: nil, excluding: []) {
            throw LedgerError.overlaps(description: describe(conflict))
        }
        let session = WorkSession(start: now, end: nil, state: .active, checkpoint: now, checkpointKind: .start,
                                  timeZoneID: calendar.timeZone.identifier, createdAt: now, updatedAt: now)
        try persist {
            try store.upsert(session)
            try store.logEvent("start", sessionID: session.id, at: now)
        }
        return session
    }

    /// Stops the timer at the actual current instant. Returns the finished session (nil if not running).
    @discardableResult
    public func stop() throws -> WorkSession? {
        guard var session = activeSession else { return nil }
        let now = clock()
        let elapsed = now.timeIntervalSince(session.start)
        if elapsed < 0 {
            // The clock moved backwards: never discard recorded work.
            throw LedgerError.clockWentBackwards
        }
        if elapsed < 1 {
            // A zero-length interval is invalid; discard it instead of storing it.
            try persist {
                try store.deleteSession(id: session.id)
                try store.logEvent("stop-discarded-empty", sessionID: session.id, at: now)
            }
            return nil
        }
        session.end = now
        session.state = .closed
        session.checkpoint = now
        session.updatedAt = now
        try persist {
            try store.upsert(session)
            try store.logEvent("stop", sessionID: session.id, at: now)
        }
        return session
    }

    /// Records a trustworthy "alive" checkpoint for the running session.
    public func checkpoint(kind: CheckpointKind) {
        guard let index = sessions.firstIndex(where: { $0.state == .active }) else { return }
        let now = clock()
        do {
            try store.updateCheckpoint(id: sessions[index].id, at: now, kind: kind)
            if kind == .sleep || kind == .wake || kind == .shutdown {
                try store.logEvent("checkpoint-\(kind.rawValue)", sessionID: sessions[index].id, at: now)
            }
            sessions[index].checkpoint = now
            sessions[index].checkpointKind = kind
        } catch {
            // A failed checkpoint only reduces recovery precision; never interrupt tracking.
        }
    }

    // MARK: Recovery

    /// Called once at launch (and after a restore). Any session still marked active belongs to a
    /// process that is no longer running (crash, force quit, power loss, reboot), so it becomes
    /// interrupted. Idempotent: already-interrupted sessions are untouched.
    @discardableResult
    public func detectInterruptions(launchTime: Date? = nil) throws -> [WorkSession] {
        let launch = launchTime ?? clock()
        var found: [WorkSession] = []
        try persist {
            for var s in try store.loadSessions() where s.state == .active {
                s.state = .interrupted
                s.detectedAt = max(launch, s.checkpoint, s.start)
                s.updatedAt = launch
                try store.upsert(s)
                try store.logEvent("interruption-detected", sessionID: s.id, at: launch,
                                   detail: "checkpoint=\(s.checkpoint.timeIntervalSinceReferenceDate) kind=\(s.checkpointKind.rawValue)")
                found.append(s)
            }
        }
        return found
    }

    /// Computes the intervals a decision would produce, validating bounds.
    public func recoveryOutcome(for session: WorkSession, decision: RecoveryDecision, continuation: RecoveryContinuation) throws -> RecoveryOutcome {
        guard session.state == .interrupted, let detected = session.detectedAt else { throw LedgerError.notInterrupted }
        let checkpoint = min(max(session.checkpoint, session.start), detected)
        var pieces: [RecoveryOutcome.Piece] = []
        switch decision {
        case .countGap:
            pieces = [.init(start: session.start, end: detected)]
        case .excludeGap:
            pieces = [.init(start: session.start, end: checkpoint)]
        case .custom(let end, let resumed):
            guard end > session.start else {
                throw LedgerError.invalidRecovery("The end time must be after the session started (\(timeString(session.start))).")
            }
            guard end <= detected else {
                throw LedgerError.invalidRecovery("The end time can't be after Workday relaunched (\(timeString(detected))). Use “Keep the timer running” to continue counting.")
            }
            pieces = [.init(start: session.start, end: end)]
            if let resumed {
                guard resumed >= end else {
                    throw LedgerError.invalidRecovery("The resume time must be at or after the end time.")
                }
                guard resumed < detected else {
                    throw LedgerError.invalidRecovery("The resume time must be before Workday relaunched (\(timeString(detected))).")
                }
                pieces.append(.init(start: resumed, end: detected))
            }
        }
        switch continuation {
        case .none:
            break
        case .fromRelaunch:
            if let last = pieces.last, last.end == detected {
                pieces[pieces.count - 1].end = nil
            } else {
                pieces.append(.init(start: detected, end: nil))
            }
        case .fromNow:
            let now = max(clock(), detected)
            if let last = pieces.last, last.end == now {
                pieces[pieces.count - 1].end = nil
            } else {
                pieces.append(.init(start: now, end: nil))
            }
        }
        // Drop empty pieces (e.g. excluding a gap when no time was confirmed).
        pieces.removeAll { p in p.end.map { $0 <= p.start } ?? false }
        return RecoveryOutcome(pieces: pieces)
    }

    /// Applies a recovery decision atomically. Calling it twice fails with `.notInterrupted`,
    /// so the gap can never be counted twice.
    public func resolveRecovery(sessionID: UUID, decision: RecoveryDecision, continuation: RecoveryContinuation) throws {
        guard let session = sessions.first(where: { $0.id == sessionID }) else { throw LedgerError.sessionNotFound }
        if continuation != .none, activeSession != nil {
            throw LedgerError.invalidRecovery("The timer is already running, so this session can't also keep running. Leave “Keep the timer running” off.")
        }
        let outcome = try recoveryOutcome(for: session, decision: decision, continuation: continuation)
        for piece in outcome.pieces {
            if let c = conflicting(start: piece.start, end: piece.end, excluding: [sessionID]) {
                throw LedgerError.overlaps(description: describe(c))
            }
        }
        let now = clock()
        try persist {
            // Re-read inside the transaction: guarantees idempotency across windows/launches.
            guard let fresh = try store.session(id: sessionID), fresh.state == .interrupted else {
                throw LedgerError.notInterrupted
            }
            if outcome.pieces.isEmpty {
                try store.deleteSession(id: sessionID)
            }
            for (i, piece) in outcome.pieces.enumerated() {
                var s = i == 0 ? fresh : WorkSession(start: piece.start, end: nil, state: .closed,
                                                    timeZoneID: fresh.timeZoneID, createdAt: now, updatedAt: now)
                s.start = piece.start
                s.end = piece.end
                s.state = piece.end == nil ? .active : .closed
                s.checkpoint = piece.end ?? now
                s.checkpointKind = piece.end == nil ? .resumed : s.checkpointKind
                s.detectedAt = nil
                s.updatedAt = now
                try store.upsert(s)
            }
            try store.logEvent("recovery-resolved", sessionID: sessionID, at: now,
                               detail: "\(decision) continue=\(continuation) pieces=\(outcome.pieces.count)")
        }
    }

    // MARK: Editing

    /// Finds a session whose reserved range overlaps `[start, end)` (`end == nil` means open-ended).
    public func conflicting(start: Date, end: Date?, excluding: Set<UUID>) -> WorkSession? {
        let e = end ?? .distantFuture
        return sessions.first { s in
            !excluding.contains(s.id) && TimeMath.overlaps(start, e, s.start, s.occupiedEnd)
        }
    }

    /// Validates a manual session; throws a `LedgerError` describing how to fix it.
    public func validate(start: Date, end: Date, excluding: UUID? = nil) throws {
        guard end > start else { throw LedgerError.endNotAfterStart }
        guard end.timeIntervalSince(start) >= Self.minimumManualSeconds else { throw LedgerError.tooShort }
        guard end <= clock().addingTimeInterval(Self.futureTolerance) else { throw LedgerError.inFuture }
        if let c = conflicting(start: start, end: end, excluding: excluding.map { [$0] } ?? []) {
            throw LedgerError.overlaps(description: describe(c))
        }
    }

    /// Manual end times may be up to `futureTolerance` ahead (minute pickers); they are clamped to now
    /// so a manual session never reserves time the timer is about to use.
    private func clampedManualEnd(_ end: Date) throws -> Date {
        let now = clock()
        guard end <= now.addingTimeInterval(Self.futureTolerance) else { throw LedgerError.inFuture }
        return min(end, now).truncatedToSecond
    }

    @discardableResult
    public func addSession(start: Date, end: Date) throws -> WorkSession {
        let start = start.truncatedToSecond
        let end = try clampedManualEnd(end)
        try validate(start: start, end: end)
        let now = clock()
        let s = WorkSession(start: start, end: end, state: .closed, checkpoint: end, checkpointKind: .heartbeat,
                            timeZoneID: calendar.timeZone.identifier, createdAt: now, updatedAt: now)
        try persist {
            try store.upsert(s)
            try store.logEvent("add", sessionID: s.id, at: now, detail: "\(start.timeIntervalSinceReferenceDate)-\(end.timeIntervalSinceReferenceDate)")
        }
        return s
    }

    public func updateSession(id: UUID, start: Date, end: Date) throws {
        guard var s = sessions.first(where: { $0.id == id }) else { throw LedgerError.sessionNotFound }
        switch s.state {
        case .active: throw LedgerError.sessionRunning
        case .interrupted: throw LedgerError.recoveryPendingForSession
        case .closed: break
        }
        let start = start.truncatedToSecond
        let end = try clampedManualEnd(end)
        try validate(start: start, end: end, excluding: id)
        let now = clock()
        let old = s
        s.start = start
        s.end = end
        s.checkpoint = end
        s.updatedAt = now
        try persist {
            try store.upsert(s)
            try store.logEvent("edit", sessionID: id, at: now,
                               detail: "from \(old.start.timeIntervalSinceReferenceDate)-\(old.end?.timeIntervalSinceReferenceDate ?? 0) to \(start.timeIntervalSinceReferenceDate)-\(end.timeIntervalSinceReferenceDate)")
        }
    }

    /// Deletes any session (a running one is discarded; an interrupted one is removed including its confirmed part).
    public func deleteSession(id: UUID) throws {
        guard let s = sessions.first(where: { $0.id == id }) else { throw LedgerError.sessionNotFound }
        let now = clock()
        try persist {
            try store.deleteSession(id: id)
            try store.logEvent("delete", sessionID: id, at: now,
                               detail: "\(s.state.rawValue) \(s.start.timeIntervalSinceReferenceDate)-\(s.end?.timeIntervalSinceReferenceDate ?? 0)")
        }
    }

    /// Per-day effect of replacing `old` with `new` (either may be nil), for the cross-day preview.
    public func impact(old: (start: Date, end: Date)?, new: (start: Date, end: Date)?) -> [(day: DayKey, before: TimeInterval, after: TimeInterval)] {
        var delta: [DayKey: TimeInterval] = [:]
        if let old { for sl in TimeMath.slices(start: old.start, end: old.end, calendar: calendar) { delta[sl.day, default: 0] -= sl.seconds } }
        if let new { for sl in TimeMath.slices(start: new.start, end: new.end, calendar: calendar) { delta[sl.day, default: 0] += sl.seconds } }
        let now = clock()
        return delta.keys.sorted().map { day in
            let before = total(for: day, now: now)
            return (day, before, max(0, before + (delta[day] ?? 0)))
        }
    }

    // MARK: Settings & notifications

    public func updateSettings(_ change: (inout WorkdaySettings) -> Void) throws {
        var s = settings
        change(&s)
        s = s.normalized()
        guard s != settings else { return }
        do { try store.saveSettings(s) } catch { throw LedgerError.storage(error.localizedDescription) }
        settings = s
        revision += 1
    }

    // MARK: Helpers

    private func persist(_ body: () throws -> Void) throws {
        do {
            try store.db.transaction { try body() }
        } catch let e as LedgerError {
            try? reload()
            throw e
        } catch {
            try? reload()
            throw LedgerError.storage(error.localizedDescription)
        }
        try reload()
    }

    private func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }

    /// "the session 09:00–12:30 on 23 Oct 2026".
    public func describe(_ s: WorkSession) -> String {
        let df = DateFormatter()
        df.calendar = calendar
        df.timeZone = calendar.timeZone
        df.setLocalizedDateFormatFromTemplate("d MMM yyyy")
        let tf = DateFormatter()
        tf.calendar = calendar
        tf.timeZone = calendar.timeZone
        tf.timeStyle = .short
        switch s.state {
        case .active:
            return "the running session that started \(tf.string(from: s.start)) on \(df.string(from: s.start))"
        case .interrupted:
            return "the interrupted session from \(tf.string(from: s.start)) on \(df.string(from: s.start)) (resolve it first)"
        case .closed:
            let end = s.end ?? s.start
            let sameDay = calendar.isDate(s.start, inSameDayAs: end)
            return sameDay
                ? "the session \(tf.string(from: s.start))–\(tf.string(from: end)) on \(df.string(from: s.start))"
                : "the session \(df.string(from: s.start)) \(tf.string(from: s.start)) – \(df.string(from: end)) \(tf.string(from: end))"
        }
    }
}

extension Date {
    var truncatedToSecond: Date {
        Date(timeIntervalSinceReferenceDate: timeIntervalSinceReferenceDate.rounded(.down))
    }
}
