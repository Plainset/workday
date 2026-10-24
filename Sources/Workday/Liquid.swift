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
        if abs(tr.to - target) > 0.0001 && abs(tr.to - target) < 0.01 && t - tr.start >= Self.fillDuration {
            // Tiny change (e.g. the live minute ticking over): apply quietly, no slosh, no fast frames.
            tr = Transition(from: target, to: target, start: t - Self.fillDuration)
            transitions[key] = tr
        } else if abs(tr.to - target) > 0.0001 {
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

    /// Last time the user interacted with these tiles (pointer movement, keys, navigation).
    private(set) var lastInteraction: Double = Date().timeIntervalSinceReferenceDate

    /// When the liquid last started waking from a still surface (for a smooth ramp back up).
    private var wakeStart: Double = -1_000
    static let wakeDuration: Double = 0.8

    func touch(t: Double = Date().timeIntervalSinceReferenceDate) {
        let current = calm(t: t)
        if current < 1 { wakeStart = t - current * Self.wakeDuration }  // continue from the current level
        lastInteraction = t
    }

    /// How long the idle drift keeps animating after the last interaction.
    static let idleDriftDuration: Double = 30
    /// Time over which idle waves ease down to a still surface after the drift period.
    static let calmDownDuration: Double = 2.5

    /// 1 while the user is engaged, easing to 0 after `idleDriftDuration` — idle waves scale with this so the
    /// liquid settles to a genuinely still frame instead of stepping at a low frame rate.
    func calm(t: Double) -> Double {
        let rampUp = min(1, max(0, (t - wakeStart) / Self.wakeDuration))
        let idle = t - lastInteraction - Self.idleDriftDuration
        guard idle > 0 else { return rampUp }
        let p = min(1, idle / Self.calmDownDuration)
        return min(rampUp, 1 - p * p * (3 - 2 * p))
    }

    func slosh(_ key: DayKey, t: Double) {
        impulses[key] = t
        touch(t: t)
    }
    func sloshAll(t: Double) { globalImpulse = t }

    /// Slosh energy 0...1, decaying after an impulse.
    func energy(for key: DayKey, t: Double) -> Double {
        let local = impulses[key].map { exp(-max(0, t - $0) * 1.3) } ?? 0
        let global = exp(-max(0, t - globalImpulse) * 1.3) * 0.6
        return min(1, local + global)
    }

    /// Perf harness only: pretend something is always moving.
    nonisolated(unsafe) static var forceSettling = false

    /// True while any transition or slosh is still settling.
    func isSettling(t: Double) -> Bool {
        if Self.forceSettling { return true }
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

    /// Draws one tile and returns the liquid body path (for clipping submerged labels), if any.
    @discardableResult
    static func draw(_ context: inout GraphicsContext,
                     cell: LiquidCell,
                     fraction: Double,
                     energy: Double,
                     calm: Double = 1,
                     time: Double,
                     motion: Bool,
                     scheme: ColorScheme) -> Path? {
        var liquidBody: Path?
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
            // A full (18 h+) tile keeps a live surface just below the brim so it still reads as liquid.
            let level = full ? r.minY + (cell.compact ? 1 : 3.5) : r.maxY - h * fraction
            let baseAmp = min(cell.compact ? 1.1 : 2.6, h * 0.035)
            let thin = min(1, fraction * 7 + 0.2)
            let amp = motion ? baseAmp * (0.6 * calm + 2.4 * energy) * thin : 0
            let segments = cell.compact ? 8 : 22

            // Back wave: lighter, offset phase, gives depth.
            let back = wave(in: r, level: level - (cell.compact ? 0.6 : 1.5), amplitude: amp * 0.85, time: tSafe,
                            phase: phase + 1.9, frequency: 1.25, speed: -0.9, segments: segments)
            inner.fill(back.fill, with: .color(Theme.liquidBack.opacity(0.45)))

            // Front body with vertical gradient.
            let front = wave(in: r, level: level, amplitude: amp, time: tSafe, phase: phase,
                             frequency: 1.0, speed: 1.35, segments: segments)
            liquidBody = front.fill
            inner.fill(front.fill, with: .linearGradient(
                Gradient(colors: [Theme.liquidTop(scheme).opacity(0.94), Theme.liquidBottom(scheme).opacity(0.97)]),
                startPoint: CGPoint(x: r.midX, y: max(level, r.minY)), endPoint: CGPoint(x: r.midX, y: r.maxY)))

            // Side gloss for a glassy, dimensional feel (skipped on tiny year tiles).
            if !cell.compact {
            inner.fill(front.fill, with: .linearGradient(
                Gradient(stops: [.init(color: .white.opacity(0.22), location: 0),
                                 .init(color: .white.opacity(0.0), location: 0.35),
                                 .init(color: .clear, location: 0.8),
                                 .init(color: Theme.orangeDeep.opacity(0.25), location: 1)]),
                startPoint: CGPoint(x: r.minX, y: r.midY), endPoint: CGPoint(x: r.maxX, y: r.midY)))

            }

            // Lit meniscus.
            do {
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
        if !cell.compact {
        g.fill(shape, with: .linearGradient(
            Gradient(colors: [.white.opacity(scheme == .dark ? 0.06 : 0.18), .clear]),
            startPoint: CGPoint(x: r.minX, y: r.minY), endPoint: CGPoint(x: r.minX + r.width * 0.6, y: r.minY + r.height * 0.6)))
        }

        // Border; brighter rim when overflowing.
        if overflow > 0 {
            g.stroke(shape, with: .linearGradient(
                Gradient(colors: [Color(red: 1, green: 0.93, blue: 0.7), Theme.orange]),
                startPoint: CGPoint(x: r.minX, y: r.minY), endPoint: CGPoint(x: r.maxX, y: r.maxY)),
                     lineWidth: cell.compact ? 1.2 : 2.2)
        } else {
            g.stroke(shape, with: .color(Theme.tileBorder(scheme)), lineWidth: 1)
        }
        return liquidBody
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

/// Draws many small (year view) tiles with a handful of batched draw calls: all tile bases in one fill,
/// all liquid bodies in one fill, all meniscus lines in one stroke, all borders in one stroke.
enum CompactLiquidPainter {
    static func draw(_ context: inout GraphicsContext, cells: [LiquidCell], motion: LiquidMotion, t: Double,
                     animatedWaves: Bool, scheme: ColorScheme) {
        var bases = Path()
        var bodies = Path()
        var surfaces = Path()
        var overflowRims = Path()
        let tSafe = t.truncatingRemainder(dividingBy: 10_000)
        for cell in cells {
            let r = cell.rect
            let radius = cell.cornerRadius
            bases.addRoundedRect(in: r, cornerSize: CGSize(width: radius, height: radius), style: .continuous)
            let fraction = cell.targetFraction // tiny tiles don't animate their fill level
            guard fraction > 0.0005 else { continue }
            let full = fraction >= 0.999
            let level = full ? r.minY + 1 : r.maxY - r.height * fraction
            // Capped at 1 pt so the static number split stays accurate on tiny tiles.
            let amp: CGFloat = animatedWaves ? min(1.0, r.height * 0.04 * (0.6 * motion.calm(t: t) + 1.4 * motion.energy(for: cell.key, t: t))) : 0
            let phase = LiquidPainter.seed(cell.key)
            let segments = 6
            // Body: wave across the top, then follow the tile's rounded bottom.
            let bottomRadius = min(radius, r.height * fraction)
            var body = Path()
            var surface = Path()
            for i in 0...segments {
                let u = Double(i) / Double(segments)
                let x = r.minX + r.width * u
                let a = 2 * .pi * u + tSafe * 1.35 + phase
                let y = max(r.minY, level + amp * sin(a))
                if i == 0 { body.move(to: CGPoint(x: x, y: y)); surface.move(to: CGPoint(x: x, y: y)) }
                else { body.addLine(to: CGPoint(x: x, y: y)); surface.addLine(to: CGPoint(x: x, y: y)) }
            }
            body.addLine(to: CGPoint(x: r.maxX, y: r.maxY - bottomRadius))
            body.addQuadCurve(to: CGPoint(x: r.maxX - bottomRadius, y: r.maxY), control: CGPoint(x: r.maxX, y: r.maxY))
            body.addLine(to: CGPoint(x: r.minX + bottomRadius, y: r.maxY))
            body.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY - bottomRadius), control: CGPoint(x: r.minX, y: r.maxY))
            body.closeSubpath()
            bodies.addPath(body)
            surfaces.addPath(surface)
            if cell.overflow > 0 {
                overflowRims.addRoundedRect(in: r, cornerSize: CGSize(width: radius, height: radius), style: .continuous)
            }
        }
        context.fill(bases, with: .color(Theme.tileBase(scheme)))
        context.fill(bodies, with: .color(Theme.liquidBottom(scheme).opacity(0.92)))
        context.stroke(surfaces, with: .color(Theme.liquidTop(scheme)), lineWidth: 1)
        context.stroke(bases, with: .color(Theme.tileBorder(scheme)), lineWidth: 0.8)
        if !overflowRims.isEmpty {
            context.drawLayer { layer in
                layer.addFilter(.blur(radius: 2.5))
                layer.stroke(overflowRims, with: .color(Theme.orange.opacity(0.9)), lineWidth: 2.5)
            }
            context.stroke(overflowRims, with: .color(Color(red: 1, green: 0.93, blue: 0.7)), lineWidth: 1.2)
        }
    }
}

/// Animation cadence policy. Frames are only produced quickly while something is actually moving
/// (a fill settling, a slosh decaying) or a live session is adding bubbles; otherwise the liquid
/// drifts at a low idle rate. Hidden windows and Reduce Motion pause the timeline entirely.
struct LiquidCadence {
    var reduceMotion: Bool
    var windowState: ControlActiveState
    var windowVisible: Bool
    var compact: Bool

    /// Perf harness only: treat the window as key even when the app isn't active.
    nonisolated(unsafe) static var forceKey = false

    var paused: Bool { reduceMotion || !windowVisible }
    /// Changes when the interval policy changes (key ↔ inactive).
    var interactiveState: Bool { !inactive }
    private var inactive: Bool { windowState == .inactive && !Self.forceKey }
    /// While a fill/slosh settles.
    var fastInterval: Double { inactive ? 1.0 / 15 : 1.0 / 30 }
    /// While a live session shows bubbles.
    var liveInterval: Double { inactive ? 1.0 / 8 : 1.0 / 12 }
    /// Gentle idle drift.
    var idleInterval: Double { inactive ? 1.0 / 4 : (compact ? 1.0 / 6 : 1.0 / 10) }
}

/// Liquid animation is driven by a structured `.task(id:)` loop per layer (see `LiquidLayer`): it sleeps for
/// an interval chosen every frame from the current state — settling → fast, live session → live rate,
/// otherwise idle drift (year tiles and long-untouched calendars hold nearly still) — and is cancelled
/// automatically when the layer disappears or pauses. (SwiftUI's TimelineView was measured redrawing near
/// display rate regardless of its schedule, so it isn't used.)
/// Picks the next frame interval for a layer.
/// Next frame interval for a layer, or nil to hold the current (still) frame until something moves.
func liquidInterval(motion: LiquidMotion, cadence: LiquidCadence, live: Bool) -> Double? {
    let now = Date().timeIntervalSinceReferenceDate
    if motion.isSettling(t: now) { return cadence.fastInterval }
    if live { return cadence.liveInterval }        // one small layer: bubbles stay smooth
    if cadence.compact { return nil }              // year tiles' idle waves are sub-pixel: hold still
    return motion.calm(t: now) > 0 ? cadence.idleInterval : nil  // drift while engaged, then a still surface
}

/// A Canvas that draws many liquid tiles — and their labels — in a single pass, driven by one
/// adaptive TimelineView. Each tile's labels are supplied twice (normal and "submerged" colours) as
/// Canvas symbols; the submerged copy is clipped to the exact wave path drawn this frame, so text stays
/// legible wherever the surface is, including during pour-in, slosh and hover growth.
struct LiquidLayer<Labels: View>: View {
    var cells: [LiquidCell]
    var motion: LiquidMotion
    var cadence: LiquidCadence
    var labels: (LiquidCell, _ submerged: Bool) -> Labels
    @Environment(\.colorScheme) private var scheme

    init(cells: [LiquidCell], motion: LiquidMotion, cadence: LiquidCadence,
         @ViewBuilder labels: @escaping (LiquidCell, _ submerged: Bool) -> Labels) {
        self.cells = cells
        self.motion = motion
        self.cadence = cadence
        self.labels = labels
    }

    @State private var t: Double = Date().timeIntervalSinceReferenceDate

    private struct AnimationKey: Equatable {
        var running: Bool
        var live: Bool
        var interactive: Bool
    }

    var body: some View {
        let live = cells.contains { $0.live }
        let running = !cadence.paused && !cells.isEmpty
        // Reduce Motion or a hidden window: one still frame of the same data, no loop.
        canvas(t: running ? t : 0)
            .task(id: AnimationKey(running: running, live: live, interactive: cadence.interactiveState)) {
                guard running else { return }
                let motion = motion, cadence = cadence
                var lastFrame = Date().timeIntervalSinceReferenceDate
                // Short slices so a hover, key or data change wakes the liquid within ~30 ms even while
                // it is holding a still frame; a frame is only produced when the chosen interval elapsed.
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 33_000_000)
                    if Task.isCancelled { break }
                    let now = Date().timeIntervalSinceReferenceDate
                    if let interval = liquidInterval(motion: motion, cadence: cadence, live: live),
                       now - lastFrame >= interval - 0.004 {
                        lastFrame = now
                        t = now
                    }
                }
            }
            .accessibilityHidden(true)
    }

    private func canvas(t: Double) -> some View {
        LiquidCanvas(cells: cells, motion: motion, paused: cadence.paused, reduceMotion: cadence.reduceMotion,
                     t: t, labels: labels)
    }
}

/// Perf harness counters (frames actually drawn).
enum LiquidStats {
    nonisolated(unsafe) static var framesDrawn = 0
    nonisolated(unsafe) static var tilesDrawn = 0

}

/// One frame of liquid tiles + labels at time `t` (shared by `LiquidLayer` and the benchmark).
struct LiquidCanvas<Labels: View>: View {
    var cells: [LiquidCell]
    var motion: LiquidMotion
    var paused: Bool
    var reduceMotion: Bool
    var t: Double
    var labels: (LiquidCell, _ submerged: Bool) -> Labels
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let first = cells.first, first.compact {
            // Year tiles: batched drawing, no per-tile label symbols.
            Canvas(rendersAsynchronously: false) { context, _ in
                LiquidStats.framesDrawn += 1
                LiquidStats.tilesDrawn += cells.count
                var ctx = context
                CompactLiquidPainter.draw(&ctx, cells: cells, motion: motion, t: t, animatedWaves: !reduceMotion && !paused,
                                          scheme: scheme)
            }
        } else {
            labelledCanvas
        }
    }

    private var labelledCanvas: some View {
        Canvas(rendersAsynchronously: false) { context, _ in
            LiquidStats.framesDrawn += 1
            LiquidStats.tilesDrawn += cells.count
            if let first = cells.first, first.compact {
                var ctx = context
                CompactLiquidPainter.draw(&ctx, cells: cells, motion: motion, t: t, animatedWaves: !reduceMotion && !paused,
                                          scheme: scheme)
                return
            }
            for (i, cell) in cells.enumerated() {
                let fraction = motion.fraction(for: cell.key, target: cell.targetFraction, t: t, animated: !paused)
                var ctx = context
                let body = LiquidPainter.draw(&ctx, cell: cell, fraction: fraction,
                                              energy: paused ? 0 : motion.energy(for: cell.key, t: t),
                                              calm: paused ? 1 : motion.calm(t: t), time: t,
                                              motion: !reduceMotion, scheme: scheme)
                var labelContext = context
                if cell.dimmed { labelContext.opacity = 0.6 }
                let split = body != nil && !cell.dimmed
                if let normal = labelContext.resolveSymbol(id: SymbolID(index: i, submerged: false)) {
                    var above = labelContext
                    // Normal colours only above the surface…
                    if split, let body { above.clip(to: body, options: .inverse) }
                    above.draw(normal, in: cell.rect)
                }
                if split, let body, let submerged = labelContext.resolveSymbol(id: SymbolID(index: i, submerged: true)) {
                    // …and high-contrast colours below it, following this frame's exact wave.
                    var below = labelContext
                    below.clip(to: body)
                    below.draw(submerged, in: cell.rect)
                }
            }
        } symbols: {
            ForEach(Array(cells.enumerated()), id: \.offset) { i, cell in
                labels(cell, false)
                    .frame(width: cell.rect.width, height: cell.rect.height)
                    .tag(SymbolID(index: i, submerged: false))
                if !cell.dimmed {
                    labels(cell, true)
                        .frame(width: cell.rect.width, height: cell.rect.height)
                        .tag(SymbolID(index: i, submerged: true))
                }
            }
        }
    }

    private struct SymbolID: Hashable {
        var index: Int
        var submerged: Bool
    }
}

extension LiquidLayer where Labels == EmptyView {
    init(cells: [LiquidCell], motion: LiquidMotion, cadence: LiquidCadence) {
        self.init(cells: cells, motion: motion, cadence: cadence) { _, _ in EmptyView() }
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

