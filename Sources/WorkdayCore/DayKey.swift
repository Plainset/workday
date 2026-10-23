import Foundation

/// A local calendar date (year, month, day) independent of time zone.
///
/// Day keys are always derived from absolute instants using a specific `Calendar`
/// (normally the current system calendar and time zone). See `docs/ARCHITECTURE.md`
/// for the date-partitioning policy.
public struct DayKey: Hashable, Comparable, Codable, Sendable, CustomStringConvertible, Identifiable {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    public init(_ date: Date, calendar: Calendar) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1)
    }

    /// Parses "yyyy-MM-dd".
    public init?(string: String) {
        let parts = string.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        self.init(year: parts[0], month: parts[1], day: parts[2])
    }

    public var id: String { description }

    public var description: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// The first instant of this local day. Robust against DST transitions that skip midnight.
    public func startDate(in calendar: Calendar) -> Date {
        let noon = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
        return calendar.startOfDay(for: noon)
    }

    /// The first instant of the following local day.
    public func endDate(in calendar: Calendar) -> Date {
        adding(days: 1, calendar: calendar).startDate(in: calendar)
    }

    /// A representative instant safely inside the day (local noon).
    public func noon(in calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    public func adding(days: Int, calendar: Calendar) -> DayKey {
        let d = calendar.date(byAdding: .day, value: days, to: noon(in: calendar))!
        return DayKey(d, calendar: calendar)
    }

    public static func < (lhs: DayKey, rhs: DayKey) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    public static func today(_ now: Date = Date(), calendar: Calendar) -> DayKey {
        DayKey(now, calendar: calendar)
    }
}

/// A calendar month (year + month).
public struct MonthKey: Hashable, Comparable, Sendable, CustomStringConvertible, Identifiable {
    public let year: Int
    public let month: Int

    public init(year: Int, month: Int) {
        self.year = year
        self.month = month
    }

    public init(_ day: DayKey) {
        self.init(year: day.year, month: day.month)
    }

    public init(_ date: Date, calendar: Calendar) {
        self.init(DayKey(date, calendar: calendar))
    }

    public var id: String { description }
    public var description: String { String(format: "%04d-%02d", year, month) }

    public var firstDay: DayKey { DayKey(year: year, month: month, day: 1) }

    public func adding(months: Int) -> MonthKey {
        let zeroBased = year * 12 + (month - 1) + months
        return MonthKey(year: Int((Double(zeroBased) / 12).rounded(.down)), month: ((zeroBased % 12) + 12) % 12 + 1)
    }

    public func numberOfDays(calendar: Calendar) -> Int {
        calendar.range(of: .day, in: .month, for: firstDay.noon(in: calendar))?.count ?? 30
    }

    public func days(calendar: Calendar) -> [DayKey] {
        (1...numberOfDays(calendar: calendar)).map { DayKey(year: year, month: month, day: $0) }
    }

    public static func < (lhs: MonthKey, rhs: MonthKey) -> Bool {
        (lhs.year, lhs.month) < (rhs.year, rhs.month)
    }
}

/// One cell of a month grid: either a day of the displayed month or a subdued adjacent-month day.
public struct MonthGridCell: Hashable, Sendable, Identifiable {
    public let day: DayKey
    public let isInDisplayedMonth: Bool
    public let row: Int
    public let column: Int
    public var id: DayKey { day }
}

public enum MonthGridLayout {
    /// Weekday column order honouring `calendar.firstWeekday`. Values are `Calendar` weekday numbers (1 = Sunday).
    public static func weekdayOrder(calendar: Calendar) -> [Int] {
        (0..<7).map { ((calendar.firstWeekday - 1 + $0) % 7) + 1 }
    }

    /// Short weekday header symbols in display order.
    public static func weekdaySymbols(calendar: Calendar, veryShort: Bool = false) -> [String] {
        let symbols = veryShort ? calendar.veryShortStandaloneWeekdaySymbols : calendar.shortStandaloneWeekdaySymbols
        return weekdayOrder(calendar: calendar).map { symbols[$0 - 1] }
    }

    /// Column (0...6) of a given date's weekday given the calendar's first weekday.
    public static func column(of day: DayKey, calendar: Calendar) -> Int {
        let weekday = calendar.component(.weekday, from: day.noon(in: calendar))
        return (weekday - calendar.firstWeekday + 7) % 7
    }

    /// Builds the grid cells for a month. Leading/trailing cells are adjacent-month days.
    /// - Parameter fixedSixRows: always emit 42 cells (stable layout when navigating).
    public static func cells(for month: MonthKey, calendar: Calendar, fixedSixRows: Bool = false) -> [MonthGridCell] {
        let first = month.firstDay
        let leading = column(of: first, calendar: calendar)
        let count = month.numberOfDays(calendar: calendar)
        let used = leading + count
        let rows = fixedSixRows ? 6 : Int((Double(used) / 7).rounded(.up))
        var result: [MonthGridCell] = []
        result.reserveCapacity(rows * 7)
        for index in 0..<(rows * 7) {
            let day = first.adding(days: index - leading, calendar: calendar)
            result.append(MonthGridCell(day: day,
                                        isInDisplayedMonth: day.year == month.year && day.month == month.month,
                                        row: index / 7,
                                        column: index % 7))
        }
        return result
    }
}
