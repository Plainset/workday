import Foundation

/// Deterministic sample history used for screenshots and manual verification only.
/// Never runs against the real data directory (see `Workday --seed-demo`).
public enum DemoData {
    /// Inserts ~10 weeks of plausible sessions ending yesterday, including a cross-midnight
    /// session, a multi-session day and an 18h+ overflow day.
    public static func seed(into store: WorkStore, endingAt today: DayKey, calendar: Calendar) throws {
        var rng = SplitMix64(seed: 0xC0FFEE)
        var sessions: [(Date, Date)] = []
        func at(_ day: DayKey, _ hour: Double) -> Date {
            day.startDate(in: calendar).addingTimeInterval(hour * 3600)
        }
        for offset in stride(from: -75, through: -1, by: 1) {
            let day = today.adding(days: offset, calendar: calendar)
            let weekday = calendar.component(.weekday, from: day.noon(in: calendar))
            let weekend = weekday == 1 || weekday == 7
            let roll = rng.nextDouble()
            if weekend && roll < 0.7 { continue }
            if !weekend && roll < 0.06 { continue }
            let startHour = 8 + rng.nextDouble() * 1.5
            let morning = 3 + rng.nextDouble() * 1.2
            let lunch = 0.5 + rng.nextDouble() * 0.5
            let afternoon = (weekend ? 1.0 : 3.2) + rng.nextDouble() * 2.4
            sessions.append((at(day, startHour), at(day, startHour + morning)))
            sessions.append((at(day, startHour + morning + lunch), at(day, startHour + morning + lunch + afternoon)))
        }
        // Special cases: cross-midnight and an overflow (19h) day.
        let crossDay = today.adding(days: -9, calendar: calendar)
        sessions.removeAll { calendar.isDate($0.0, inSameDayAs: at(crossDay, 12)) || calendar.isDate($0.0, inSameDayAs: at(crossDay, 36)) }
        sessions.append((at(crossDay, 14), at(crossDay, 18)))
        sessions.append((at(crossDay, 23.5), at(crossDay, 25.25)))
        let bigDay = today.adding(days: -16, calendar: calendar)
        sessions.removeAll { calendar.isDate($0.0, inSameDayAs: at(bigDay, 12)) }
        sessions.append((at(bigDay, 4), at(bigDay, 23)))
        // A second overflow day in the previous month (21h) for month-to-month evidence.
        let bigDay2 = today.adding(days: -34, calendar: calendar)
        sessions.removeAll { calendar.isDate($0.0, inSameDayAs: at(bigDay2, 12)) }
        sessions.append((at(bigDay2, 2), at(bigDay2, 23)))

        try store.db.transaction {
            for (s, e) in sessions.sorted(by: { $0.0 < $1.0 }) {
                try store.upsert(WorkSession(start: s, end: e, state: .closed, checkpoint: e, checkpointKind: .heartbeat,
                                             timeZoneID: calendar.timeZone.identifier, createdAt: e, updatedAt: e))
            }
        }
    }
}

/// Small deterministic PRNG.
public struct SplitMix64 {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    public mutating func nextDouble() -> Double { Double(next() >> 11) / Double(1 << 53) }
}
