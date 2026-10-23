import Foundation
import Testing
@testable import WorkdayCore

@MainActor
@Suite("Crash and restart recovery (A05)")
struct RecoveryTests {
    /// Starts at 09:00, last checkpoint 11:00, "crash", relaunch at 13:00 in a new process.
    func crashScenario() throws -> (WorkLedger, TestClock, URL) {
        let (ledger, clock, dir) = try makeLedger(at: date(2026, 10, 23, 9, 0))
        try ledger.start()
        clock.now = date(2026, 10, 23, 11, 0)
        ledger.checkpoint(kind: .heartbeat)
        // Process dies here. Relaunch:
        clock.now = date(2026, 10, 23, 13, 0)
        let store = try WorkStore(path: dir.appendingPathComponent("workday.sqlite").path)
        let relaunched = try WorkLedger(store: store, calendar: calendar(), clock: { clock.now })
        let found = try relaunched.detectInterruptions()
        #expect(found.count == 1)
        return (relaunched, clock, dir)
    }

    @Test("Unresolved session survives relaunch and the gap is not silently counted")
    func pendingNotCounted() throws {
        let (ledger, clock, dir) = try crashScenario()
        let today = ledger.today()
        #expect(ledger.isRunning == false)
        #expect(ledger.hasPendingRecovery)
        #expect(ledger.total(for: today) == 2 * 3600)          // confirmed: 09:00–11:00
        #expect(ledger.pendingSeconds(for: today) == 2 * 3600) // pending: 11:00–13:00
        // Detecting again (another launch) is idempotent.
        let store = try WorkStore(path: dir.appendingPathComponent("workday.sqlite").path)
        let again = try WorkLedger(store: store, calendar: calendar(), clock: { clock.now })
        #expect(try again.detectInterruptions().isEmpty)
        #expect(again.pendingRecoveries.count == 1)
        #expect(again.total(for: today) == 2 * 3600)
    }

    @Test("Count the gap: counts start through relaunch, exactly once")
    func countGap() throws {
        let (ledger, _, _) = try crashScenario()
        let id = ledger.pendingRecoveries[0].id
        try ledger.resolveRecovery(sessionID: id, decision: .countGap, continueTracking: false)
        #expect(ledger.total(for: ledger.today()) == 4 * 3600)
        #expect(ledger.pendingSeconds(for: ledger.today()) == 0)
        #expect(!ledger.hasPendingRecovery)
        #expect(throws: (any Error).self) { try ledger.resolveRecovery(sessionID: id, decision: .countGap, continueTracking: false) }
        #expect(ledger.total(for: ledger.today()) == 4 * 3600)
    }

    @Test("Exclude the gap: confirmed portion survives")
    func excludeGap() throws {
        let (ledger, _, _) = try crashScenario()
        try ledger.resolveRecovery(sessionID: ledger.pendingRecoveries[0].id, decision: .excludeGap, continueTracking: false)
        #expect(ledger.total(for: ledger.today()) == 2 * 3600)
        #expect(!ledger.hasPendingRecovery)
        #expect(ledger.sessions.count == 1)
    }

    @Test("Custom end and resume split the gap")
    func customSplit() throws {
        let (ledger, _, _) = try crashScenario()
        let id = ledger.pendingRecoveries[0].id
        try ledger.resolveRecovery(sessionID: id,
                                   decision: .custom(end: date(2026, 10, 23, 11, 30), resumedAt: date(2026, 10, 23, 12, 15)),
                                   continueTracking: false)
        // 09:00–11:30 (2.5h) + 12:15–13:00 (0.75h)
        #expect(ledger.total(for: ledger.today()) == 3.25 * 3600)
        #expect(ledger.sessions.count == 2)
    }

    @Test("Custom bounds are validated")
    func customValidation() throws {
        let (ledger, _, _) = try crashScenario()
        let s = ledger.pendingRecoveries[0]
        #expect(throws: (any Error).self) { try ledger.recoveryOutcome(for: s, decision: .custom(end: date(2026, 10, 23, 8), resumedAt: nil), continueTracking: false) }
        #expect(throws: (any Error).self) { try ledger.recoveryOutcome(for: s, decision: .custom(end: date(2026, 10, 23, 14), resumedAt: nil), continueTracking: false) }
        #expect(throws: (any Error).self) { try ledger.recoveryOutcome(for: s, decision: .custom(end: date(2026, 10, 23, 12), resumedAt: date(2026, 10, 23, 11)), continueTracking: false) }
        #expect(ledger.hasPendingRecovery)
    }

    @Test("Count the gap and keep running continues the same session")
    func continueTracking() throws {
        let (ledger, clock, _) = try crashScenario()
        try ledger.resolveRecovery(sessionID: ledger.pendingRecoveries[0].id, decision: .countGap, continueTracking: true)
        #expect(ledger.isRunning)
        clock.now = date(2026, 10, 23, 14, 0)
        #expect(ledger.total(for: ledger.today()) == 5 * 3600)
    }

    @Test("Exclude and keep running starts a new interval at the relaunch time")
    func excludeAndContinue() throws {
        let (ledger, clock, _) = try crashScenario()
        try ledger.resolveRecovery(sessionID: ledger.pendingRecoveries[0].id, decision: .excludeGap, continueTracking: true)
        clock.now = date(2026, 10, 23, 14, 0)
        #expect(ledger.total(for: ledger.today()) == 3 * 3600) // 2h confirmed + 13:00–14:00
        #expect(ledger.sessions.count == 2)
    }

    @Test("Starting a new session while recovery is pending never double counts the gap")
    func startWhilePending() throws {
        let (ledger, clock, _) = try crashScenario()
        try ledger.start()
        clock.now = date(2026, 10, 23, 14, 0)
        let id = ledger.pendingRecoveries[0].id
        #expect(throws: (any Error).self) { try ledger.resolveRecovery(sessionID: id, decision: .countGap, continueTracking: true) }
        try ledger.resolveRecovery(sessionID: id, decision: .countGap, continueTracking: false)
        #expect(ledger.total(for: ledger.today()) == 5 * 3600) // 09–13 + 13–14
        // A manual session inside the pending gap would have been refused:
        #expect(ledger.conflicting(start: date(2026, 10, 23, 12), end: date(2026, 10, 23, 12, 30), excluding: []) != nil)
    }

    @Test("Shutdown checkpoint is reported as an exact stop")
    func shutdownCheckpoint() throws {
        let (ledger, clock, dir) = try makeLedger(at: date(2026, 10, 23, 9, 0))
        try ledger.start()
        clock.now = date(2026, 10, 23, 17, 0)
        ledger.checkpoint(kind: .shutdown)
        clock.now = date(2026, 10, 24, 8, 0)
        let relaunched = try WorkLedger(store: try WorkStore(path: dir.appendingPathComponent("workday.sqlite").path),
                                        calendar: calendar(), clock: { clock.now })
        try relaunched.detectInterruptions()
        let s = relaunched.pendingRecoveries[0]
        #expect(s.checkpointKind == .shutdown)
        #expect(s.checkpointKind.isExactStop)
        #expect(relaunched.total(for: DayKey(year: 2026, month: 10, day: 23)) == 8 * 3600)
    }
}
