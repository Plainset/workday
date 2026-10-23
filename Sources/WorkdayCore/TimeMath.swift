import Foundation

/// Pure calendar math: splitting absolute intervals into local calendar days.
///
/// Policy: durations are absolute elapsed seconds (`end - start`); allocation to dates uses the
/// supplied calendar's time zone (normally the current system time zone). A DST change therefore
/// changes the length of a local day (23h/25h) but never the measured duration of work.
public enum TimeMath {
    /// Splits `[start, end)` into per-local-day portions, in chronological order.
    public static func slices(start: Date, end: Date, calendar: Calendar) -> [(day: DayKey, seconds: TimeInterval)] {
        guard end > start else { return [] }
        var result: [(DayKey, TimeInterval)] = []
        var cursor = start
        while cursor < end {
            let key = DayKey(cursor, calendar: calendar)
            var next = key.endDate(in: calendar)
            if next <= cursor { next = cursor.addingTimeInterval(86_400) } // defensive: never loop forever
            let segmentEnd = min(end, next)
            result.append((key, segmentEnd.timeIntervalSince(cursor)))
            cursor = segmentEnd
        }
        return result
    }

    /// Seconds of `[start, end)` that fall on `day`.
    public static func seconds(of start: Date, _ end: Date, on day: DayKey, calendar: Calendar) -> TimeInterval {
        let dayStart = day.startDate(in: calendar)
        let dayEnd = day.endDate(in: calendar)
        let s = max(start, dayStart)
        let e = min(end, dayEnd)
        return max(0, e.timeIntervalSince(s))
    }

    /// Accumulates per-day totals for a set of intervals.
    public static func dailyTotals(_ intervals: [(start: Date, end: Date)], calendar: Calendar) -> [DayKey: TimeInterval] {
        var totals: [DayKey: TimeInterval] = [:]
        for interval in intervals {
            for slice in slices(start: interval.start, end: interval.end, calendar: calendar) {
                totals[slice.day, default: 0] += slice.seconds
            }
        }
        return totals
    }

    /// Whether `[aStart, aEnd)` and `[bStart, bEnd)` overlap (touching endpoints do not overlap).
    public static func overlaps(_ aStart: Date, _ aEnd: Date, _ bStart: Date, _ bEnd: Date) -> Bool {
        aStart < bEnd && bStart < aEnd
    }

    /// Minutes since local midnight for `date`.
    public static func minuteOfDay(_ date: Date, calendar: Calendar) -> Int {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }
}

/// Display formatting. Internals keep full precision; values are floored to whole minutes/seconds here only.
public enum DurationFormat {
    /// "6h 35m", "45m", "19h", "0m".
    public static func short(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds) / 60)
        let h = total / 60, m = total % 60
        if h == 0 { return "\(m)m" }
        if m == 0 { return "\(h)h" }
        return "\(h)h \(m)m"
    }

    /// Compact clock for the menu bar: "6:35", "0:00", "19:05".
    public static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds) / 60)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// "1:23:45" for live counters.
    public static func precise(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    /// "6 hours 35 minutes" for VoiceOver.
    public static func spoken(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds) / 60)
        let h = total / 60, m = total % 60
        let hp = h == 1 ? "1 hour" : "\(h) hours"
        let mp = m == 1 ? "1 minute" : "\(m) minutes"
        if h == 0 && m == 0 { return "no time worked" }
        if h == 0 { return mp }
        if m == 0 { return hp }
        return "\(hp) \(mp)"
    }

    /// "8h" / "7h 30m" for goal values given in minutes.
    public static func goal(minutes: Int) -> String {
        short(TimeInterval(minutes * 60))
    }
}

/// The liquid fill scale: empty at 0h, full at 18h, overflow treatment beyond 18h.
public enum LiquidScale {
    public static let fullHours: Double = 18
    public static let fullSeconds: TimeInterval = fullHours * 3600

    /// Fill fraction in `0...1` (visual only; totals are never clamped).
    public static func fillFraction(seconds: TimeInterval) -> Double {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return min(1, seconds / fullSeconds)
    }

    /// True only beyond 18 hours.
    public static func isOverflowing(seconds: TimeInterval) -> Bool {
        seconds > fullSeconds
    }

    /// 0 at 18h rising smoothly to 1 at 24h; drives the strength of the overflow effect.
    public static func overflowIntensity(seconds: TimeInterval) -> Double {
        guard isOverflowing(seconds: seconds) else { return 0 }
        let extra = (seconds - fullSeconds) / (6 * 3600)
        return min(1, 0.35 + 0.65 * extra)
    }
}
