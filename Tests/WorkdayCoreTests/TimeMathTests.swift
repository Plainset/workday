import Foundation
import Testing
@testable import WorkdayCore

@Suite("Calendar math (A03, A04, A07, A08)")
struct TimeMathTests {
    @Test("A03: 23:30–01:15 gives 30m to day one and 75m to day two")
    func midnightSplit() {
        let cal = calendar()
        let slices = TimeMath.slices(start: date(2026, 10, 20, 23, 30), end: date(2026, 10, 21, 1, 15), calendar: cal)
        #expect(slices.count == 2)
        #expect(slices[0].day == DayKey(year: 2026, month: 10, day: 20))
        #expect(slices[0].seconds == 30 * 60)
        #expect(slices[1].day == DayKey(year: 2026, month: 10, day: 21))
        #expect(slices[1].seconds == 75 * 60)
    }

    @Test("Multi-day interval splits into each full local day")
    func multiDay() {
        let cal = calendar()
        let slices = TimeMath.slices(start: date(2026, 3, 1, 22), end: date(2026, 3, 4, 2), calendar: cal)
        #expect(slices.map(\.seconds) == [TimeInterval]([2 * 3600, 86_400, 86_400, 2 * 3600]))
    }

    @Test("A04: DST spring-forward night keeps absolute duration; dates stable")
    func dstSpringForward() {
        // Europe/Amsterdam: 29 Mar 2026 02:00 -> 03:00 (23-hour day)
        let cal = calendar()
        let start = date(2026, 3, 28, 23, 0)
        let end = date(2026, 3, 29, 4, 0)
        #expect(end.timeIntervalSince(start) == 4 * 3600) // wall clock says 5h, absolute is 4h
        let slices = TimeMath.slices(start: start, end: end, calendar: cal)
        #expect(slices.count == 2)
        #expect(slices[0].seconds == 3600)
        #expect(slices[1].seconds == 3 * 3600)
        #expect(slices.reduce(0) { $0 + $1.seconds } == end.timeIntervalSince(start))
        // The full DST day is 23h long.
        let d = DayKey(year: 2026, month: 3, day: 29)
        #expect(d.endDate(in: cal).timeIntervalSince(d.startDate(in: cal)) == 23 * 3600)
    }

    @Test("A04: DST fall-back night (25-hour day) counts the repeated hour once as real time")
    func dstFallBack() {
        // Europe/Amsterdam: 25 Oct 2026 03:00 -> 02:00
        let cal = calendar()
        let start = date(2026, 10, 25, 0, 0)
        let end = date(2026, 10, 25, 6, 0)
        #expect(end.timeIntervalSince(start) == 7 * 3600)
        let totals = TimeMath.dailyTotals([(start, end)], calendar: cal)
        #expect((totals[DayKey(year: 2026, month: 10, day: 25)] ?? -1) == 7 * 3600)
        let d = DayKey(year: 2026, month: 10, day: 25)
        #expect(d.endDate(in: cal).timeIntervalSince(d.startDate(in: cal)) == 25 * 3600)
    }

    @Test("A04: Time zone change re-partitions dates using the current zone, durations unchanged")
    func timeZoneChange() {
        let ams = calendar("Europe/Amsterdam")
        let ny = calendar("America/New_York")
        let start = date(2026, 6, 10, 23, 0, cal: ams)   // 17:00 in New York
        let end = date(2026, 6, 11, 2, 0, cal: ams)      // 20:00 in New York
        let a = TimeMath.dailyTotals([(start, end)], calendar: ams)
        let n = TimeMath.dailyTotals([(start, end)], calendar: ny)
        #expect((a[DayKey(year: 2026, month: 6, day: 10)] ?? -1) == 3600)
        #expect((a[DayKey(year: 2026, month: 6, day: 11)] ?? -1) == 2 * 3600)
        #expect((n[DayKey(year: 2026, month: 6, day: 10)] ?? -1) == 3 * 3600)
        #expect(a.values.reduce(0, +) == n.values.reduce(0, +))
    }

    @Test("A07: fill scale 0h empty, 9h half, 18h full, 19h full plus overflow")
    func liquidScale() {
        #expect(LiquidScale.fillFraction(seconds: 0) == 0)
        #expect(LiquidScale.fillFraction(seconds: 9 * 3600) == 0.5)
        #expect(LiquidScale.fillFraction(seconds: 18 * 3600) == 1)
        #expect(LiquidScale.isOverflowing(seconds: 18 * 3600) == false)
        #expect(LiquidScale.fillFraction(seconds: 19 * 3600) == 1)
        #expect(LiquidScale.isOverflowing(seconds: 19 * 3600))
        #expect(LiquidScale.overflowIntensity(seconds: 19 * 3600) > 0)
        #expect(DurationFormat.short(19 * 3600) == "19h")
        #expect(DurationFormat.short(6 * 3600 + 35 * 60 + 59) == "6h 35m")
        #expect(DurationFormat.short(0) == "0m")
        #expect(DurationFormat.clock(6 * 3600 + 35 * 60) == "6:35")
        #expect(DurationFormat.spoken(19 * 3600) == "19 hours")
    }

    @Test("A08: month grids align weekdays, include leap day, and cover every day exactly once")
    func monthGrids() {
        let cal = calendar() // Monday first
        for year in 2024...2028 {
            for month in 1...12 {
                let m = MonthKey(year: year, month: month)
                let cells = MonthGridLayout.cells(for: m, calendar: cal)
                let inMonth = cells.filter(\.isInDisplayedMonth)
                #expect(inMonth.count == m.numberOfDays(calendar: cal))
                #expect(cells.count % 7 == 0)
                for cell in cells {
                    let weekday = cal.component(.weekday, from: cell.day.noon(in: cal))
                    #expect(MonthGridLayout.weekdayOrder(calendar: cal)[cell.column] == weekday)
                }
                // consecutive
                for (a, b) in zip(cells, cells.dropFirst()) {
                    #expect(a.day.adding(days: 1, calendar: cal) == b.day)
                }
            }
        }
        #expect(MonthKey(year: 2028, month: 2).numberOfDays(calendar: cal) == 29)
        #expect(MonthKey(year: 2026, month: 2).numberOfDays(calendar: cal) == 28)
        #expect(MonthGridLayout.weekdaySymbols(calendar: cal).first == "Mon")
        var us = Calendar(identifier: .gregorian); us.firstWeekday = 1; us.locale = Locale(identifier: "en_US")
        #expect(MonthGridLayout.weekdaySymbols(calendar: us).first == "Sun")
        // October 2026 starts on a Thursday -> column 3 when Monday is first
        #expect(MonthGridLayout.column(of: DayKey(year: 2026, month: 10, day: 1), calendar: cal) == 3)
        #expect(MonthKey(year: 2026, month: 1).adding(months: -1) == MonthKey(year: 2025, month: 12))
        #expect(MonthKey(year: 2026, month: 12).adding(months: 1) == MonthKey(year: 2027, month: 1))
        #expect(MonthGridLayout.cells(for: MonthKey(year: 2026, month: 2), calendar: cal, fixedSixRows: true).count == 42)
    }
}
