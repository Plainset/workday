import SwiftUI
import WorkdayCore

/// Everything the painter needs for one tile.
struct LiquidCell {
    var key: DayKey
    var rect: CGRect
    var cornerRadius: CGFloat
    /// Exact worked seconds (fill and overflow are derived from this via `LiquidScale`).
    var seconds: TimeInterval
    var dimmed: Bool
    /// A running session is adding to this day: show rising bubbles.
    var live: Bool
    var compact: Bool = false

    var targetFraction: Double { LiquidScale.fillFraction(seconds: seconds) }
    var overflow: Double { LiquidScale.overflowIntensity(seconds: seconds) }
}

/// Per-tile animation state (fill transitions and slosh impulses). A reference type so the Canvas
/// can read/update it every frame without triggering SwiftUI invalidation.
final class LiquidMotion {
    private struct Transition { var from: Double; var to: Double; var start: Double }
    private var transitions: [DayKey: Transition] = [:]
    private var impulses: [DayKey: Double] = [:]
    private var globalImpulse: Double = -1_000

    static let fillDuration: Double = 1.25
    /// Offscreen snapshots render a single frame, so fills must appear settled immediately.
    nonisolated(unsafe) static var settleInstantly = false

    /// Fill to draw at time `t`. New/changed targets animate with a damped settle and trigger a slosh.
    func fraction(for key: DayKey, target: Double, t: Double, animated: Bool) -> Double {
        guard animated, !Self.settleInstantly else {
            transitions[key] = Transition(from: target, to: target, start: t - Self.fillDuration)
            return target
        }
        guard var tr = transitions[key] else {
            transitions[key] = Transition(from: 0, to: target, start: t)
            if target > 0 { impulses[key] = t }
            return 0
        }
        if abs(tr.to - target) > 0.0001 {
            let current = value(tr, t)
            tr = Transition(from: current, to: target, start: t)
            transitions[key] = tr
            impulses[key] = t
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

    func slosh(_ key: DayKey, t: Double) { impulses[key] = t }
    func sloshAll(t: Double) { globalImpulse = t }

    /// Slosh energy 0...1, decaying after an impulse.
    func energy(for key: DayKey, t: Double) -> Double {
        let local = impulses[key].map { exp(-max(0, t - $0) * 1.3) } ?? 0
        let global = exp(-max(0, t - globalImpulse) * 1.3) * 0.6
        return min(1, local + global)
    }

    /// True while any transition or slosh is still settling.
    func isSettling(t: Double) -> Bool {
        if t - globalImpulse < 3 { return true }
        if impulses.values.contains(where: { t - $0 < 3 }) { return true }
        return transitions.values.contains { t - $0.start < Self.fillDuration }
    }
}

/// Draws translucent orange liquid with layered waves, a lit meniscus, depth shading,
/// bubbles for live days and a glowing rim + foam for days beyond 18 hours.
enum LiquidPainter {
    static func seed(_ key: DayKey) -> Double {
        var x = UInt64(key.year * 10_000 + key.month * 100 + key.day) &* 0x9E3779B97F4A7C15
        x ^= x >> 29
        return Double(x % 10_000) / 10_000 * 2 * .pi
    }

    static func draw(_ context: inout GraphicsContext,
                     cell: LiquidCell,
                     fraction: Double,
                     energy: Double,
                     time: Double,
                     motion: Bool,
                     scheme: ColorScheme) {
        let r = cell.rect
        let shape = Path(roundedRect: r, cornerRadius: cell.cornerRadius, style: .continuous)
        var g = context
        if cell.dimmed { g.opacity = 0.4 }

        let overflow = cell.overflow
        let pulse = motion ? 0.75 + 0.25 * sin(time * 2.2 + seed(cell.key)) : 1

        // Overflow glow sits outside the tile.
        if overflow > 0 {
            g.drawLayer { layer in
                layer.addFilter(.blur(radius: cell.compact ? 2.5 : 7))
                layer.stroke(shape, with: .color(Theme.orange.opacity(0.85 * overflow * pulse)),
                             lineWidth: cell.compact ? 2.5 : 6)
            }
        }

        g.fill(shape, with: .color(Theme.tileBase(scheme)))

        let tSafe = time.truncatingRemainder(dividingBy: 10_000)
        let phase = seed(cell.key)
        if fraction > 0.0005 {
            var inner = g
            inner.clip(to: shape)
            let h = r.height
            let full = fraction >= 0.999
            let level = full ? r.minY - (cell.compact ? 2 : 5) : r.maxY - h * fraction
            let baseAmp = min(cell.compact ? 1.1 : 2.6, h * 0.035)
            let thin = min(1, fraction * 7 + 0.2)
            let amp = motion ? baseAmp * (0.6 + 2.4 * energy) * thin : 0
            let segments = cell.compact ? 8 : 22

            // Back wave: lighter, offset phase, gives depth.
            let back = wave(in: r, level: level - (cell.compact ? 0.6 : 1.5), amplitude: amp * 0.85, time: tSafe,
                            phase: phase + 1.9, frequency: 1.25, speed: -0.9, segments: segments)
            inner.fill(back.fill, with: .color(Theme.liquidBack.opacity(0.45)))

            // Front body with vertical gradient.
            let front = wave(in: r, level: level, amplitude: amp, time: tSafe, phase: phase,
                             frequency: 1.0, speed: 1.35, segments: segments)
            inner.fill(front.fill, with: .linearGradient(
                Gradient(colors: [Theme.liquidTop(scheme).opacity(0.94), Theme.liquidBottom(scheme).opacity(0.97)]),
                startPoint: CGPoint(x: r.midX, y: max(level, r.minY)), endPoint: CGPoint(x: r.midX, y: r.maxY)))

            // Side gloss for a glassy, dimensional feel.
            inner.fill(front.fill, with: .linearGradient(
                Gradient(stops: [.init(color: .white.opacity(0.22), location: 0),
                                 .init(color: .white.opacity(0.0), location: 0.35),
                                 .init(color: .clear, location: 0.8),
                                 .init(color: Theme.orangeDeep.opacity(0.25), location: 1)]),
                startPoint: CGPoint(x: r.minX, y: r.midY), endPoint: CGPoint(x: r.maxX, y: r.midY)))

            // Lit meniscus.
            if !full || overflow > 0 {
                inner.stroke(front.surface, with: .color(.white.opacity(scheme == .dark ? 0.55 : 0.7)),
                             lineWidth: cell.compact ? 0.6 : 1.3)
            }

            // Bubbles: live days and overflow days.
            if motion && (cell.live || overflow > 0) && !cell.compact {
                let count = overflow > 0 ? 9 : 6
                for i in 0..<count {
                    let fi = Double(i)
                    let speed = 0.12 + 0.07 * frac(sin(fi * 12.9898 + phase) * 43758.5453)
                    let p = frac(tSafe * speed + fi * 0.37 + phase)
                    let x = r.minX + r.width * (0.12 + 0.76 * frac(sin(fi * 78.233 + phase) * 12345.678))
                        + sin(tSafe * 2 + fi) * 2
                    let top = max(level + 3, r.minY + 3)
                    let y = r.maxY - 3 - (r.maxY - 3 - top) * p
                    let radius = (overflow > 0 ? 1.6 : 1.2) + fi.truncatingRemainder(dividingBy: 3) * 0.5
                    let alpha = 0.55 * (1 - p) + 0.15
                    inner.fill(Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)),
                               with: .color(.white.opacity(alpha)))
                }
            }

            // Overflow foam along the brim.
            if overflow > 0 && !cell.compact {
                for i in 0..<7 {
                    let fi = Double(i)
                    let x = r.minX + r.width * (fi + 0.5) / 7 + (motion ? sin(tSafe * 1.7 + fi * 1.3) * 3 : 0)
                    let y = r.minY + 2 + (motion ? sin(tSafe * 2.4 + fi) * 1.2 : 0)
                    let rad = 2.2 + (fi.truncatingRemainder(dividingBy: 2)) * 1.3
                    inner.fill(Path(ellipseIn: CGRect(x: x - rad, y: y - rad, width: rad * 2, height: rad * 2)),
                               with: .color(.white.opacity(0.45 * overflow + 0.15)))
                }
            }
        }

        // Glass highlight over the whole tile.
        g.fill(shape, with: .linearGradient(
            Gradient(colors: [.white.opacity(scheme == .dark ? 0.06 : 0.18), .clear]),
            startPoint: CGPoint(x: r.minX, y: r.minY), endPoint: CGPoint(x: r.minX + r.width * 0.6, y: r.minY + r.height * 0.6)))

        // Border; brighter rim when overflowing.
        if overflow > 0 {
            g.stroke(shape, with: .linearGradient(
                Gradient(colors: [Color(red: 1, green: 0.93, blue: 0.7), Theme.orange]),
                startPoint: CGPoint(x: r.minX, y: r.minY), endPoint: CGPoint(x: r.maxX, y: r.maxY)),
                     lineWidth: cell.compact ? 1.2 : 2.2)
        } else {
            g.stroke(shape, with: .color(Theme.tileBorder(scheme)), lineWidth: 1)
        }
    }

    private static func frac(_ x: Double) -> Double { x - x.rounded(.down) }

    /// Builds the liquid body and its surface curve.
    static func wave(in r: CGRect, level: CGFloat, amplitude: CGFloat, time: Double, phase: Double,
                     frequency: Double, speed: Double, segments: Int) -> (fill: Path, surface: Path) {
        var surface = Path()
        var fill = Path()
        fill.move(to: CGPoint(x: r.minX, y: r.maxY + 1))
        for i in 0...segments {
            let u = Double(i) / Double(segments)
            let x = r.minX + r.width * u
            let a = 2 * .pi * frequency * u + time * speed + phase
            let y = level + amplitude * (sin(a) + 0.35 * sin(2.3 * a - time * 0.7 + phase * 1.7))
            let pt = CGPoint(x: x, y: y)
            if i == 0 {
                surface.move(to: pt)
            } else {
                surface.addLine(to: pt)
            }
            fill.addLine(to: pt)
        }
        fill.addLine(to: CGPoint(x: r.maxX, y: r.maxY + 1))
        fill.closeSubpath()
        return (fill, surface)
    }
}

/// Animation cadence policy: smooth while the window is key, gentle while visible in the
/// background, paused when hidden or when Reduce Motion is on.
struct LiquidCadence {
    var reduceMotion: Bool
    var windowState: ControlActiveState
    var windowVisible: Bool
    var compact: Bool

    var paused: Bool { reduceMotion || !windowVisible }
    var interval: Double {
        if windowState == .inactive { return 1.0 / 8 }
        return compact ? 1.0 / 20 : 1.0 / 40
    }
}

/// A Canvas that draws many liquid tiles in a single pass, driven by one TimelineView.
struct LiquidLayer: View {
    var cells: [LiquidCell]
    var motion: LiquidMotion
    var cadence: LiquidCadence
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        TimelineView(.animation(minimumInterval: cadence.interval, paused: cadence.paused)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas(rendersAsynchronously: false) { context, _ in
                for cell in cells {
                    let fraction = motion.fraction(for: cell.key, target: cell.targetFraction, t: t, animated: !cadence.reduceMotion)
                    var ctx = context
                    LiquidPainter.draw(&ctx, cell: cell, fraction: fraction,
                                       energy: motion.energy(for: cell.key, t: t), time: t,
                                       motion: !cadence.reduceMotion, scheme: scheme)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

private struct ForceReducedMotionKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Forces the still-liquid presentation (used for evidence snapshots of Reduce Motion).
    var forceReducedMotion: Bool {
        get { self[ForceReducedMotionKey.self] }
        set { self[ForceReducedMotionKey.self] = newValue }
    }
}
