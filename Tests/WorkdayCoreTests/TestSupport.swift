import Foundation
@testable import WorkdayCore

/// A controllable clock for deterministic tests.
final class TestClock {
    var now: Date
    init(_ now: Date) { self.now = now }
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

func calendar(_ tz: String = "Europe/Amsterdam") -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: tz)!
    c.firstWeekday = 2
    c.locale = Locale(identifier: "en_GB")
    return c
}

func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0, _ s: Int = 0, cal: Calendar = calendar()) -> Date {
    cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min, second: s))!
}

func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("workday-tests-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@MainActor
func makeLedger(at start: Date, cal: Calendar = calendar(), dir: URL = tempDir()) throws -> (WorkLedger, TestClock, URL) {
    let clock = TestClock(start)
    let store = try WorkStore(path: dir.appendingPathComponent("workday.sqlite").path)
    let ledger = try WorkLedger(store: store, calendar: cal, clock: { clock.now })
    return (ledger, clock, dir)
}
