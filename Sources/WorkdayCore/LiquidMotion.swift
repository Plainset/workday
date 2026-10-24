import Foundation

/// Per-tile animation state (fill transitions and slosh impulses). A reference type so the Canvas
/// can read/update it every frame without triggering SwiftUI invalidation.
public final class LiquidMotion {
    private struct Transition { var from: Double; var to: Double; var start: Double }
    private var transitions: [DayKey: Transition] = [:]
    private var impulses: [DayKey: Double] = [:]
    private var globalImpulse: Double = -1_000

    public static let fillDuration: Double = 1.25
    /// Offscreen snapshots render a single frame, so fills must appear settled immediately.
    nonisolated(unsafe) public static var settleInstantly = false

    /// Wall clock. A layer holding a still frame redraws with its last (possibly minutes-old) frame time
    /// when data changes, so new transitions and impulses are stamped with the real time instead —
    /// otherwise they would look already finished and the liquid would keep its old level.
    private let wallClock: () -> Double

    public init(wallClock: @escaping () -> Double = { Date().timeIntervalSinceReferenceDate }) {
        self.wallClock = wallClock
        self.lastInteraction = wallClock()
    }

    /// Fill to draw at time `t`. New/changed targets animate with a damped settle and trigger a slosh.
    public func fraction(for key: DayKey, target: Double, t: Double, animated: Bool) -> Double {
        guard animated, !Self.settleInstantly else {
            transitions[key] = Transition(from: target, to: target, start: t - Self.fillDuration)
            return target
        }
        let stamp = max(t, wallClock())
        guard var tr = transitions[key] else {
            transitions[key] = Transition(from: 0, to: target, start: stamp)
            if target > 0 { impulses[key] = stamp }
            return 0
        }
        if abs(tr.to - target) > 0.0001 && abs(tr.to - target) < 0.01 && t - tr.start >= Self.fillDuration {
            // Tiny change (e.g. the live minute ticking over): apply quietly, no slosh, no fast frames.
            tr = Transition(from: target, to: target, start: t - Self.fillDuration)
            transitions[key] = tr
        } else if abs(tr.to - target) > 0.0001 {
            // Start from the level actually reached by now (not at a stale frame time).
            let current = value(tr, stamp)
            tr = Transition(from: current, to: target, start: stamp)
            transitions[key] = tr
            impulses[key] = stamp
        }
        return value(tr, t)
    }

    private func value(_ tr: Transition, _ t: Double) -> Double {
        let p = min(1, max(0, (t - tr.start) / Self.fillDuration))
        if p >= 1 { return tr.to }
        // Damped spring settle: overshoots slightly then rests.
        let eased = 1 - exp(-5.5 * p) * cos(7.5 * p)
        return tr.from + (tr.to - tr.from) * eased
    }

    /// Last time the user interacted with these tiles (pointer movement, keys, navigation).
    public private(set) var lastInteraction: Double

    /// When the liquid last started waking from a still surface (for a smooth ramp back up).
    private var wakeStart: Double = -1_000
    public static let wakeDuration: Double = 0.8

    public func touch(t: Double = Date().timeIntervalSinceReferenceDate) {
        let current = calm(t: t)
        if current < 1 { wakeStart = t - current * Self.wakeDuration }  // continue from the current level
        lastInteraction = t
    }

    /// How long the idle drift keeps animating after the last interaction.
    public static let idleDriftDuration: Double = 30
    /// Time over which idle waves ease down to a still surface after the drift period.
    public static let calmDownDuration: Double = 2.5

    /// 1 while the user is engaged, easing to 0 after `idleDriftDuration` — idle waves scale with this so the
    /// liquid settles to a genuinely still frame instead of stepping at a low frame rate.
    public func calm(t: Double) -> Double {
        let rampUp = min(1, max(0, (t - wakeStart) / Self.wakeDuration))
        let idle = t - lastInteraction - Self.idleDriftDuration
        guard idle > 0 else { return rampUp }
        let p = min(1, idle / Self.calmDownDuration)
        return min(rampUp, 1 - p * p * (3 - 2 * p))
    }

    public func slosh(_ key: DayKey, t: Double) {
        let stamp = max(t, wallClock())
        impulses[key] = stamp
        touch(t: stamp)
    }
    public func sloshAll(t: Double) { globalImpulse = max(t, wallClock()) }

    /// Slosh energy 0...1, decaying after an impulse.
    public func energy(for key: DayKey, t: Double) -> Double {
        let local = impulses[key].map { exp(-max(0, t - $0) * 1.3) } ?? 0
        let global = exp(-max(0, t - globalImpulse) * 1.3) * 0.6
        return min(1, local + global)
    }

    /// Perf harness only: pretend something is always moving.
    nonisolated(unsafe) public static var forceSettling = false

    /// True while any transition or slosh is still settling.
    public func isSettling(t: Double) -> Bool {
        if Self.forceSettling { return true }
        if t - globalImpulse < 3 { return true }
        if impulses.values.contains(where: { t - $0 < 3 }) { return true }
        return transitions.values.contains { t - $0.start < Self.fillDuration }
    }
}

