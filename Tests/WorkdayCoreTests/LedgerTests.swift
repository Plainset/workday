import Foundation
import Testing
@testable import WorkdayCore

@MainActor
@Suite("Timer, sessions and editing (A01, A02, A06)")
struct LedgerTests {
    @Test("A01: Start/Stop/Start accumulates; Start is idempotent; history survives reopening")
    func startStopAccumulates() throws {
        let (ledger, clock, dir) = try makeLedger(at: date(2026, 10, 23, 9, 0))
        let first = try ledger.start()
        let again = try ledger.start()
        #expect(first.id == again.id)
        #expect(ledger.sessions.count == 1)
        clock.advance(2 * 3600)
        try ledger.stop()
        clock.advance(1800)
        try ledger.start()
        clock.advance(3600 + 15 * 60)
        #expect(ledger.total(for: ledger.today()) == 3 * 3600 + 15 * 60)
        try ledger.stop()
        #expect(try ledger.stop() == nil) // stop when stopped is a no-op
        let today = ledger.today()
        #expect(ledger.total(for: today) == 3 * 3600 + 15 * 60)

        // Simulate restarting the UI: brand-new ledger on the same database.
        let store2 = try WorkStore(path: dir.appendingPathComponent("workday.sqlite").path)
        let ledger2 = try WorkLedger(store: store2, calendar: calendar(), clock: { clock.now })
        #expect(ledger2.total(for: today) == 3 * 3600 + 15 * 60)
        #expect(ledger2.sessions.count == 2)
        let events = try store2.events().map(\.kind)
        #expect(events.filter { $0 == "start" }.count == 2)
        #expect(events.filter { $0 == "stop" }.count == 2)
    }

    @Test("A02: active session counts wall-clock time across sleep without pausing")
    func sleepCounts() throws {
        let (ledger, clock, _) = try makeLedger(at: date(2026, 10, 23, 9, 0))
        try ledger.start()
        clock.advance(600)
        ledger.checkpoint(kind: .sleep)
        clock.advance(3 * 3600) // asleep, process suspended; no ticks
        ledger.checkpoint(kind: .wake)
        #expect(ledger.total(for: ledger.today()) == 3 * 3600 + 600)
        #expect(ledger.activeSession?.checkpointKind == .wake)
        try ledger.stop()
        #expect(ledger.total(for: ledger.today()) == 3 * 3600 + 600)
        #expect(ledger.pendingRecoveries.isEmpty)
    }

    @Test("A03: live session crossing midnight updates both days")
    func liveMidnight() throws {
        let (ledger, clock, _) = try makeLedger(at: date(2026, 10, 20, 23, 30))
        try ledger.start()
        clock.now = date(2026, 10, 21, 1, 15)
        #expect(ledger.today() == DayKey(year: 2026, month: 10, day: 21))
        #expect(ledger.total(for: DayKey(year: 2026, month: 10, day: 20)) == 1800)
        #expect(ledger.total(for: DayKey(year: 2026, month: 10, day: 21)) == 75 * 60)
        try ledger.stop()
        #expect(ledger.total(for: DayKey(year: 2026, month: 10, day: 20)) == 1800)
        #expect(ledger.total(for: DayKey(year: 2026, month: 10, day: 21)) == 75 * 60)
    }

    @Test("A06: add, edit and delete past sessions update totals immediately")
    func editing() throws {
        let (ledger, _, _) = try makeLedger(at: date(2026, 10, 23, 18, 0))
        let day = DayKey(year: 2026, month: 10, day: 20)
        let s = try ledger.addSession(start: date(2026, 10, 20, 9), end: date(2026, 10, 20, 12))
        #expect(ledger.total(for: day) == 3 * 3600)
        #expect(LiquidScale.fillFraction(seconds: ledger.total(for: day)) == 3.0 / 18.0)
        try ledger.updateSession(id: s.id, start: date(2026, 10, 20, 9), end: date(2026, 10, 20, 18))
        #expect(ledger.total(for: day) == 9 * 3600)
        #expect(LiquidScale.fillFraction(seconds: ledger.total(for: day)) == 0.5)
        // Editing across midnight recalculates both days.
        try ledger.updateSession(id: s.id, start: date(2026, 10, 20, 22), end: date(2026, 10, 21, 3))
        #expect(ledger.total(for: day) == 2 * 3600)
        #expect(ledger.total(for: DayKey(year: 2026, month: 10, day: 21)) == 3 * 3600)
        try ledger.deleteSession(id: s.id)
        #expect(ledger.total(for: day) == 0)
        #expect(ledger.total(for: DayKey(year: 2026, month: 10, day: 21)) == 0)
    }

    @Test("A06: invalid and overlapping ranges are rejected without corrupting data")
    func validation() throws {
        let (ledger, _, _) = try makeLedger(at: date(2026, 10, 23, 18, 0))
        let a = try ledger.addSession(start: date(2026, 10, 20, 9), end: date(2026, 10, 20, 12))
        #expect(throws: LedgerError.endNotAfterStart) { try ledger.addSession(start: date(2026, 10, 20, 14), end: date(2026, 10, 20, 13)) }
        #expect(throws: LedgerError.endNotAfterStart) { try ledger.addSession(start: date(2026, 10, 20, 14), end: date(2026, 10, 20, 14)) }
        #expect(throws: LedgerError.tooShort) { try ledger.addSession(start: date(2026, 10, 20, 14), end: date(2026, 10, 20, 14, 0, 30)) }
        #expect(throws: LedgerError.inFuture) { try ledger.addSession(start: date(2026, 10, 23, 17), end: date(2026, 10, 23, 20)) }
        do {
            try ledger.addSession(start: date(2026, 10, 20, 11), end: date(2026, 10, 20, 13))
            Issue.record("overlap accepted")
        } catch let e as LedgerError {
            if case .overlaps = e {} else { Issue.record("wrong error \(e)") }
        }
        // Touching endpoints are fine.
        let b = try ledger.addSession(start: date(2026, 10, 20, 12), end: date(2026, 10, 20, 13))
        // Editing b to overlap a is rejected and leaves b unchanged.
        #expect(throws: (any Error).self) { try ledger.updateSession(id: b.id, start: date(2026, 10, 20, 10), end: date(2026, 10, 20, 13)) }
        #expect(ledger.total(for: DayKey(year: 2026, month: 10, day: 20)) == 4 * 3600)
        #expect(ledger.sessions.count == 2)
        // Editing a session against itself is allowed.
        try ledger.updateSession(id: a.id, start: date(2026, 10, 20, 8), end: date(2026, 10, 20, 12))
        #expect(ledger.total(for: DayKey(year: 2026, month: 10, day: 20)) == 5 * 3600)
    }

    @Test("Running session can't be edited and blocks overlapping manual entries")
    func runningProtection() throws {
        let (ledger, clock, _) = try makeLedger(at: date(2026, 10, 23, 9, 0))
        let s = try ledger.start()
        clock.advance(3600)
        #expect(throws: LedgerError.sessionRunning) { try ledger.updateSession(id: s.id, start: date(2026, 10, 23, 8), end: date(2026, 10, 23, 9, 30)) }
        #expect(throws: (any Error).self) { try ledger.addSession(start: date(2026, 10, 23, 9, 10), end: date(2026, 10, 23, 9, 40)) }
        try ledger.addSession(start: date(2026, 10, 23, 7), end: date(2026, 10, 23, 8))
        #expect(ledger.total(for: ledger.today()) == 2 * 3600)
    }

    @Test("Total time beyond 18h is never clipped")
    func noClipping() throws {
        let (ledger, _, _) = try makeLedger(at: date(2026, 10, 23, 23, 59))
        try ledger.addSession(start: date(2026, 10, 22, 2), end: date(2026, 10, 22, 21))
        let t = ledger.total(for: DayKey(year: 2026, month: 10, day: 22))
        #expect(t == 19 * 3600)
        #expect(DurationFormat.short(t) == "19h")
        #expect(LiquidScale.isOverflowing(seconds: t))
    }

    @Test("Cross-day impact preview lists other affected days")
    func impact() throws {
        let (ledger, _, _) = try makeLedger(at: date(2026, 10, 23, 18, 0))
        let rows = ledger.impact(old: nil, new: (date(2026, 10, 20, 23, 30), date(2026, 10, 21, 1, 15)))
        #expect(rows.count == 2)
        #expect(rows[0].after - rows[0].before == 1800)
        #expect(rows[1].after - rows[1].before == 75 * 60)
    }

    @Test("Sessions touching a day include cross-midnight sessions on both days")
    func touching() throws {
        let (ledger, _, _) = try makeLedger(at: date(2026, 10, 23, 18, 0))
        let s = try ledger.addSession(start: date(2026, 10, 20, 23, 30), end: date(2026, 10, 21, 1, 15))
        #expect(ledger.sessions(touching: DayKey(year: 2026, month: 10, day: 20)).map(\.id) == [s.id])
        #expect(ledger.sessions(touching: DayKey(year: 2026, month: 10, day: 21)).map(\.id) == [s.id])
        #expect(ledger.sessions(touching: DayKey(year: 2026, month: 10, day: 22)).isEmpty)
        #expect(ledger.portion(of: s, on: DayKey(year: 2026, month: 10, day: 21)) == 75 * 60)
    }
}
