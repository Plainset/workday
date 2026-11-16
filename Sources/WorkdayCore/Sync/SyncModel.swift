import Foundation

/// A hybrid logical clock timestamp: wall-clock milliseconds, a counter for events within the same
/// millisecond (or while the local clock lags behind one already seen), and the device that issued it.
///
/// Ordering is (wall, counter, device). Because a device's clock never issues a value below the largest one it
/// has observed, an edit made after seeing another Mac's edit always sorts after it — even if this Mac's
/// wall clock is behind — so a skewed clock can't silently lose edits.
public struct HybridTimestamp: Comparable, Hashable, Sendable, CustomStringConvertible {
    public var wall: Int64
    public var counter: Int64
    public var device: String

    public init(wall: Int64, counter: Int64, device: String) {
        self.wall = wall
        self.counter = counter
        self.device = device
    }

    public static func < (a: Self, b: Self) -> Bool {
        (a.wall, a.counter, a.device) < (b.wall, b.counter, b.device)
    }

    /// Fixed-width text form, e.g. `001763290000000-000000-<device>`; sorts like the value.
    public var description: String {
        String(format: "%015lld-%06lld-", wall, counter) + device
    }

    public init?(_ text: String) {
        let parts = text.split(separator: "-", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 15, parts[1].count == 6,
              let wall = Int64(parts[0]), let counter = Int64(parts[1]), wall >= 0, counter >= 0,
              SyncValidation.isDeviceID(String(parts[2])) else { return nil }
        self.init(wall: wall, counter: counter, device: String(parts[2]))
    }

    public static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
    }
}

/// Issues hybrid timestamps for one device.
public struct HybridClock: Sendable {
    public private(set) var last: HybridTimestamp
    public let device: String

    public init(device: String, last: HybridTimestamp?) {
        self.device = device
        self.last = last.map { HybridTimestamp(wall: $0.wall, counter: $0.counter, device: device) }
            ?? HybridTimestamp(wall: 0, counter: 0, device: device)
    }

    /// A new timestamp greater than every one issued or observed so far.
    public mutating func tick(now: Date) -> HybridTimestamp {
        let wall = HybridTimestamp.milliseconds(now)
        if wall > last.wall {
            last = HybridTimestamp(wall: wall, counter: 0, device: device)
        } else {
            last = HybridTimestamp(wall: last.wall, counter: last.counter + 1, device: device)
        }
        return last
    }

    /// Advances past a timestamp received from another device.
    public mutating func observe(_ other: HybridTimestamp) {
        if (other.wall, other.counter) > (last.wall, last.counter) {
            last = HybridTimestamp(wall: other.wall, counter: other.counter, device: device)
        }
    }
}

/// One change exchanged through the sync folder (one JSON Lines line, or one entry of a snapshot).
///
/// Kinds:
/// * `session` — the full state of a session (last writer wins per session).
/// * `tombstone` — a session was deleted (wins over older edits).
/// * `setting` — one synced settings field (last writer wins per field).
/// * `notified` — a notification was delivered for a day (grow-only set).
/// * `checkpoint` — a running session's latest "alive" moment. Advisory only: never overrides an edit.
public struct SyncRecord: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case session, tombstone, setting, notified, checkpoint
    }

    public var seq: Int64?
    public var hlc: String
    public var kind: Kind

    // session / tombstone / checkpoint
    public var id: String?
    public var start: Double?
    public var end: Double?
    public var state: String?
    public var checkpoint: Double?
    public var checkpointKind: String?
    public var detectedAt: Double?
    public var tz: String?
    public var createdAt: Double?
    public var owner: String?

    // setting
    public var field: String?
    public var value: Int?

    // notified
    public var day: String?
    public var reminder: String?
    public var sentAt: Double?

    public init(seq: Int64? = nil, hlc: String, kind: Kind) {
        self.seq = seq
        self.hlc = hlc
        self.kind = kind
    }

    public static func session(_ s: WorkSession, hlc: HybridTimestamp) -> SyncRecord {
        var r = SyncRecord(hlc: hlc.description, kind: .session)
        r.id = s.id.uuidString
        r.start = s.start.timeIntervalSinceReferenceDate
        r.end = s.end?.timeIntervalSinceReferenceDate
        r.state = s.state.rawValue
        r.checkpoint = s.checkpoint.timeIntervalSinceReferenceDate
        r.checkpointKind = s.checkpointKind.rawValue
        r.detectedAt = s.detectedAt?.timeIntervalSinceReferenceDate
        r.tz = s.timeZoneID
        r.createdAt = s.createdAt.timeIntervalSinceReferenceDate
        r.owner = s.ownerDevice
        return r
    }

    public static func tombstone(id: String, hlc: HybridTimestamp) -> SyncRecord {
        var r = SyncRecord(hlc: hlc.description, kind: .tombstone)
        r.id = id
        return r
    }

    public static func setting(_ field: String, value: Int, hlc: HybridTimestamp) -> SyncRecord {
        var r = SyncRecord(hlc: hlc.description, kind: .setting)
        r.field = field
        r.value = value
        return r
    }

    public static func notified(day: String, reminder: String, sentAt: Double, hlc: HybridTimestamp) -> SyncRecord {
        var r = SyncRecord(hlc: hlc.description, kind: .notified)
        r.day = day
        r.reminder = reminder
        r.sentAt = sentAt
        return r
    }

    public static func checkpoint(of s: WorkSession, hlc: HybridTimestamp) -> SyncRecord {
        var r = SyncRecord(hlc: hlc.description, kind: .checkpoint)
        r.id = s.id.uuidString
        r.checkpoint = s.checkpoint.timeIntervalSinceReferenceDate
        r.checkpointKind = s.checkpointKind.rawValue
        return r
    }

    /// The session described by a validated `session` record, or nil if any field is out of bounds.
    public func validatedSession(updatedAt: Date) -> WorkSession? {
        guard kind == .session,
              let idText = id, let uuid = UUID(uuidString: idText),
              let start, SyncValidation.isPlausibleInstant(start),
              let stateText = state, let state = SessionState(rawValue: stateText),
              let checkpoint, SyncValidation.isPlausibleInstant(checkpoint),
              let kindText = checkpointKind, let cpKind = CheckpointKind(rawValue: kindText),
              let tz, SyncValidation.isTimeZoneText(tz),
              let createdAt, SyncValidation.isPlausibleInstant(createdAt),
              let owner, SyncValidation.isDeviceID(owner) else { return nil }
        switch state {
        case .closed:
            guard let end, SyncValidation.isPlausibleInstant(end), end > start,
                  end - start <= SyncValidation.maximumSessionSeconds else { return nil }
        case .active, .interrupted:
            guard end == nil else { return nil }
        }
        if let detectedAt { guard SyncValidation.isPlausibleInstant(detectedAt) else { return nil } }
        if state == .interrupted { guard detectedAt != nil else { return nil } }
        return WorkSession(id: uuid,
                           start: Date(timeIntervalSinceReferenceDate: start),
                           end: end.map(Date.init(timeIntervalSinceReferenceDate:)),
                           state: state,
                           checkpoint: Date(timeIntervalSinceReferenceDate: checkpoint),
                           checkpointKind: cpKind,
                           detectedAt: state == .interrupted ? detectedAt.map(Date.init(timeIntervalSinceReferenceDate:)) : nil,
                           timeZoneID: tz,
                           createdAt: Date(timeIntervalSinceReferenceDate: createdAt),
                           updatedAt: updatedAt,
                           ownerDevice: owner)
    }
}

/// Bounds applied to everything read from the sync folder, which is treated as untrusted input.
public enum SyncValidation {
    /// 2000-01-01 … 2100-01-01 (seconds since the reference date 2001-01-01).
    static let earliestInstant: Double = -31_622_400
    static let latestInstant: Double = 3_124_137_600
    /// A finished session longer than this is rejected as implausible.
    public static let maximumSessionSeconds: Double = 400 * 24 * 3600
    /// Largest file read from the sync folder.
    public static let maximumFileBytes = 16 * 1024 * 1024
    /// Longest single record line.
    public static let maximumLineBytes = 4096
    /// Records whose clock is further ahead of this Mac than this are rejected.
    public static let maximumClockLead: TimeInterval = 366 * 24 * 3600

    static func isPlausibleInstant(_ t: Double) -> Bool {
        t.isFinite && t >= earliestInstant && t <= latestInstant
    }

    public static func isDeviceID(_ text: String) -> Bool {
        text.count == 36 && UUID(uuidString: text)?.uuidString == text
    }

    static func isTimeZoneText(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.count <= 64 && text.unicodeScalars.allSatisfy { $0.isASCII && !CharacterSet.controlCharacters.contains($0) }
    }

    static func isDayText(_ text: String) -> Bool {
        let parts = text.split(separator: "-")
        guard text.count == 10, parts.count == 3, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return false }
        return (2000...2100).contains(y) && (1...12).contains(m) && (1...31).contains(d)
    }

    /// Device names are shown in Settings; strip control characters and cap the length.
    public static func cleanName(_ name: String) -> String {
        let scalars = name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let cleaned = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        return String(cleaned.prefix(64))
    }
}

/// Settings fields that sync between Macs. Everything else in `WorkdaySettings` (first-launch and
/// login-item bookkeeping) stays per device.
public enum SyncedSetting: String, CaseIterable, Sendable {
    case dailyGoalMinutes
    case goalNotificationEnabled
    case startReminderEnabled
    case startReminderMinutes
    case stopReminderEnabled
    case stopReminderMinutes

    public func value(in s: WorkdaySettings) -> Int {
        switch self {
        case .dailyGoalMinutes: return s.dailyGoalMinutes
        case .goalNotificationEnabled: return s.goalNotificationEnabled ? 1 : 0
        case .startReminderEnabled: return s.startReminderEnabled ? 1 : 0
        case .startReminderMinutes: return s.startReminderMinutes
        case .stopReminderEnabled: return s.stopReminderEnabled ? 1 : 0
        case .stopReminderMinutes: return s.stopReminderMinutes
        }
    }

    /// Applies a value received from another Mac; returns false if it's out of range.
    public func apply(_ value: Int, to s: inout WorkdaySettings) -> Bool {
        switch self {
        case .dailyGoalMinutes:
            guard (WorkdaySettings.minimumGoalMinutes...WorkdaySettings.maximumGoalMinutes).contains(value) else { return false }
            s.dailyGoalMinutes = value
        case .startReminderMinutes, .stopReminderMinutes:
            guard (0..<(24 * 60)).contains(value) else { return false }
            if self == .startReminderMinutes { s.startReminderMinutes = value } else { s.stopReminderMinutes = value }
        case .goalNotificationEnabled, .startReminderEnabled, .stopReminderEnabled:
            guard value == 0 || value == 1 else { return false }
            let on = value == 1
            switch self {
            case .goalNotificationEnabled: s.goalNotificationEnabled = on
            case .startReminderEnabled: s.startReminderEnabled = on
            default: s.stopReminderEnabled = on
            }
        }
        return true
    }
}

/// Stable content fingerprint (FNV-1a, 64 bit) used to detect local changes since the last sync.
enum SyncHash {
    static func of(_ text: String) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in text.utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
        return String(format: "%016llx", h)
    }

    /// The fields that make a session's synced content. A running session's checkpoint is excluded: it
    /// changes every 30 s and travels separately as an advisory `checkpoint` record.
    static func session(_ s: WorkSession) -> String {
        var parts = [s.id.uuidString, String(s.start.timeIntervalSinceReferenceDate),
                     s.end.map { String($0.timeIntervalSinceReferenceDate) } ?? "-", s.state.rawValue,
                     s.detectedAt.map { String($0.timeIntervalSinceReferenceDate) } ?? "-", s.timeZoneID, s.ownerDevice]
        if s.state != .active {
            parts += [String(s.checkpoint.timeIntervalSinceReferenceDate), s.checkpointKind.rawValue]
        }
        return of(parts.joined(separator: "|"))
    }
}
