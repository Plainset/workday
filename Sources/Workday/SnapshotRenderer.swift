import AppKit
import SwiftUI
import WorkdayCore

/// Renders deterministic evidence images (light/dark month, year, popover, tiles, reduced motion)
/// from demo data in a throwaway directory. Never touches the user's real data.
@MainActor
enum SnapshotRenderer {
    static func run(outputDirectory: URL) {
        LiquidMotion.settleInstantly = true
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let cal = Calendar.autoupdatingCurrent
        let today = DayKey(Date(), calendar: cal)
        let now = today.startDate(in: cal).addingTimeInterval(14 * 3600 + 20 * 60)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("workday-snapshot-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        do {
            let store = try WorkStore(path: tmp.appendingPathComponent("workday.sqlite").path)
            try DemoData.seed(into: store, endingAt: today, calendar: cal)
            var clock = today.startDate(in: cal).addingTimeInterval(8 * 3600 + 50 * 60)
            let ledger = try WorkLedger(store: store, calendar: cal, clock: { clock })
            try ledger.start()
            clock = today.startDate(in: cal).addingTimeInterval(12 * 3600 + 5 * 60)
            try ledger.stop()
            clock = today.startDate(in: cal).addingTimeInterval(12 * 3600 + 50 * 60)
            try ledger.start()
            clock = now
            let model = AppModel(ledger: ledger, backups: BackupManager(store: store, directory: tmp.appendingPathComponent("Backups")),
                                 notifications: NotificationService(), launchAtLogin: LaunchAtLogin())
            model.tick(now)

            let month = MonthKey(today)
            for scheme in [ColorScheme.light, .dark] {
                let name = scheme == .light ? "light" : "dark"
                render(CalendarRootView(initialMonth: month, mode: .month, snapshotNow: now).environment(model),
                       size: CGSize(width: 1060, height: 800), scheme: scheme, to: outputDirectory.appendingPathComponent("month-\(name).png"))
                render(CalendarRootView(initialMonth: month, mode: .year, snapshotNow: now).environment(model),
                       size: CGSize(width: 1060, height: 800), scheme: scheme, to: outputDirectory.appendingPathComponent("year-\(name).png"))
                render(MenuPopoverView().environment(model),
                       size: CGSize(width: 320, height: 330), scheme: scheme, to: outputDirectory.appendingPathComponent("popover-\(name).png"))
            }
            // Previous month: contains a 21 h overflow day in the demo data.
            let previous = MonthKey(today).adding(months: -1)
            for scheme in [ColorScheme.light, .dark] {
                render(CalendarRootView(initialMonth: previous, mode: .month, snapshotNow: now).environment(model),
                       size: CGSize(width: 1060, height: 800), scheme: scheme,
                       to: outputDirectory.appendingPathComponent("month-previous-overflow-\(scheme == .light ? "light" : "dark").png"))
                // Minimum window size.
                render(CalendarRootView(initialMonth: month, mode: .month, snapshotNow: now).environment(model),
                       size: CGSize(width: 760, height: 620), scheme: scheme,
                       to: outputDirectory.appendingPathComponent("month-minsize-\(scheme == .light ? "light" : "dark").png"))
                render(CalendarRootView(initialMonth: month, mode: .year, snapshotNow: now).environment(model),
                       size: CGSize(width: 760, height: 620), scheme: scheme,
                       to: outputDirectory.appendingPathComponent("year-minsize-\(scheme == .light ? "light" : "dark").png"))
            }
            // Leap-year February layout.
            render(CalendarRootView(initialMonth: MonthKey(year: 2028, month: 2), mode: .month, snapshotNow: now).environment(model),
                   size: CGSize(width: 1060, height: 800), scheme: .light, to: outputDirectory.appendingPathComponent("month-leap-feb-2028-light.png"))
            renderStatusItems(to: outputDirectory.appendingPathComponent("status-items.png"))
            // Common intermediate window size for the year view.
            render(CalendarRootView(initialMonth: month, mode: .year, snapshotNow: now).environment(model),
                   size: CGSize(width: 900, height: 800), scheme: .dark, to: outputDirectory.appendingPathComponent("year-900x800-dark.png"))
            // Strong slosh: labels must follow the drawn wave (clipped per frame).
            for scheme in [ColorScheme.light, .dark] {
                render(TileScale(slosh: true).environment(model), size: CGSize(width: 760, height: 210), scheme: scheme,
                       to: outputDirectory.appendingPathComponent("tiles-slosh-\(scheme == .light ? "light" : "dark").png"))
            }
            render(CalendarRootView(initialMonth: month, mode: .month, snapshotNow: now).environment(model)
                    .environment(\.forceReducedMotion, true),
                   size: CGSize(width: 1060, height: 800), scheme: .dark, to: outputDirectory.appendingPathComponent("month-reduced-motion-dark.png"))
            render(TileScale().environment(model), size: CGSize(width: 760, height: 210), scheme: .light,
                   to: outputDirectory.appendingPathComponent("tiles-scale-light.png"))
            render(TileScale().environment(model), size: CGSize(width: 760, height: 210), scheme: .dark,
                   to: outputDirectory.appendingPathComponent("tiles-scale-dark.png"))

            // Empty state: fresh store, no sessions.
            let emptyStore = try WorkStore(path: tmp.appendingPathComponent("empty.sqlite").path)
            let emptyLedger = try WorkLedger(store: emptyStore, calendar: cal, clock: { now })
            let emptyModel = AppModel(ledger: emptyLedger, backups: BackupManager(store: emptyStore, directory: tmp),
                                      notifications: NotificationService(), launchAtLogin: LaunchAtLogin())
            render(CalendarRootView(initialMonth: month, mode: .month, snapshotNow: now).environment(emptyModel),
                   size: CGSize(width: 1060, height: 800), scheme: .light, to: outputDirectory.appendingPathComponent("month-empty-light.png"))
            render(MenuPopoverView().environment(emptyModel), size: CGSize(width: 320, height: 300), scheme: .light,
                   to: outputDirectory.appendingPathComponent("popover-empty-light.png"))

            // Pending recovery state in the popover.
            try emptyLedger.addSession(start: now.addingTimeInterval(-5 * 3600), end: now.addingTimeInterval(-4 * 3600))
            var c2 = now.addingTimeInterval(-3 * 3600)
            let recStore = try WorkStore(path: tmp.appendingPathComponent("rec.sqlite").path)
            let recLedger = try WorkLedger(store: recStore, calendar: cal, clock: { c2 })
            try recLedger.start()
            c2 = now.addingTimeInterval(-2 * 3600)
            recLedger.checkpoint(kind: .heartbeat)
            c2 = now
            try recLedger.detectInterruptions()
            let recModel = AppModel(ledger: recLedger, backups: BackupManager(store: recStore, directory: tmp),
                                    notifications: NotificationService(), launchAtLogin: LaunchAtLogin())
            render(MenuPopoverView().environment(recModel), size: CGSize(width: 320, height: 430), scheme: .light,
                   to: outputDirectory.appendingPathComponent("popover-recovery-light.png"))
            print("Snapshots written to \(outputDirectory.path)")
        } catch {
            FileHandle.standardError.write("Snapshot failed: \(error)\n".data(using: .utf8)!)
            exit(1)
        }
    }

    /// Times offscreen rendering of real liquid frames (CPU rasterisation via ImageRenderer — an upper bound
    /// compared with the GPU-composited live window) and prints ms/frame plus implied CPU at each cadence.
    static func benchmark() {
        LiquidMotion.settleInstantly = false
        let cal = Calendar.autoupdatingCurrent
        let month = MonthKey(Date(), calendar: cal)
        var rng = SplitMix64(seed: 7)
        let monthCells: [LiquidCell] = MonthGridLayout.cells(for: month, calendar: cal).map { c in
            let w: CGFloat = 140, h: CGFloat = 104
            return LiquidCell(key: c.day, rect: CGRect(x: CGFloat(c.column) * (w + 9), y: CGFloat(c.row) * (h + 9), width: w, height: h),
                              cornerRadius: 16, seconds: rng.nextDouble() * 20 * 3600, dimmed: !c.isInDisplayedMonth, live: false)
        }
        var yearCells: [LiquidCell] = []
        for m in 1...12 {
            let mk = MonthKey(year: month.year, month: m)
            let ox = CGFloat((m - 1) % 4) * 250, oy = CGFloat((m - 1) / 4) * 230
            for c in MonthGridLayout.cells(for: mk, calendar: cal, fixedSixRows: true) where c.isInDisplayedMonth {
                yearCells.append(LiquidCell(key: c.day, rect: CGRect(x: ox + CGFloat(c.column) * 29, y: oy + CGFloat(c.row) * 29, width: 26, height: 26),
                                            cornerRadius: 6, seconds: rng.nextDouble() * 12 * 3600, dimmed: false, live: false, compact: true))
            }
        }
        func time(_ name: String, cells: [LiquidCell], size: CGSize, frames: Int, compact: Bool) {
            // One persistent renderer whose view graph is updated each frame, like the live TimelineView.
            let clock = BenchClock()
            let motion = LiquidMotion()
            clock.t = Date().timeIntervalSinceReferenceDate
            let renderer = ImageRenderer(content: BenchView(clock: clock, cells: cells, motion: motion, compact: compact)
                .frame(width: size.width, height: size.height))
            renderer.scale = 2
            _ = renderer.cgImage // warm-up (first layout, symbol resolution)
            let start = Date()
            var distinct = Set<Int>()
            for _ in 0..<frames {
                clock.t += 1.0 / 40
                RunLoop.current.run(mode: .default, before: Date())  // let the graph observe the change
                if let image = renderer.cgImage { distinct.insert(image.hashValue) }
            }
            print("  (\(distinct.count) distinct frames)")
            let ms = Date().timeIntervalSince(start) * 1000 / Double(frames)
            let cadence = LiquidCadence(reduceMotion: false, windowState: .key, windowVisible: true, compact: compact)
            func cpu(_ interval: Double) -> String { String(format: "%.1f%%", ms / 1000 / interval * 100) }
            let idle = compact ? "static when idle (0.5 s hold)" : String(format: "idle %.0f fps ≈ %@ CPU", 1 / cadence.idleInterval, cpu(cadence.idleInterval))
            print(String(format: "%@: %.2f ms/frame (%d tiles) → %@, settling %.0f fps ≈ %@ CPU",
                         name, ms, cells.count, idle, 1 / cadence.fastInterval, cpu(cadence.fastInterval)))
        }
        if ProcessInfo.processInfo.environment["BENCH_EMPTY"] != nil {
            time("empty-canvas", cells: [], size: CGSize(width: 1050, height: 680), frames: 60, compact: false)
        }
        time("month", cells: monthCells, size: CGSize(width: 1050, height: 680), frames: 120, compact: false)
        time("year", cells: yearCells, size: CGSize(width: 1000, height: 700), frames: 60, compact: true)
        time("live tile only", cells: [monthCells[10]].map { var c = $0; c.live = true; c.rect.origin = .zero; return c },
             size: CGSize(width: 140, height: 104), frames: 200, compact: false)
    }

    /// Perf run inside the real app lifecycle:
    /// `WORKDAY_DATA_DIR=<scratch> Workday --seed-demo --perf <scenario>` where scenario is one of
    /// menubar, month-idle, month-untouched, month-live, month-live-untouched, month-motion, year-idle, year-motion.
    /// Hosts the calendar in a nearly transparent, click-through window that never activates the app
    /// and samples this process's CPU time (getrusage). One scenario per process, so nothing lingers.
    static func perf(model: AppModel) {
        LiquidCadence.forceKey = true
        let scenario = CommandLine.arguments.drop { $0 != "--perf" }.dropFirst().first ?? "month-idle"
        func cpuSeconds() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
                + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
        }
        let mode: CalendarMode? = scenario.hasPrefix("month") ? .month : scenario.hasPrefix("year") ? .year : nil
        if scenario.contains("live") { model.start() }
        var window: NSWindow?
        if let mode {
            let w = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 1060, height: 800), styleMask: [.titled],
                             backing: .buffered, defer: false)
            w.contentViewController = NSHostingController(rootView: CalendarRootView(initialMonth: MonthKey(model.today), mode: mode,
                                                                                     snapshotNow: Date()).environment(model))
            w.alphaValue = 0.03
            w.ignoresMouseEvents = true
            w.orderFrontRegardless()
            model.calendarVisible = true
            window = w
        }
        if scenario.hasSuffix("motion") { LiquidMotion.forceSettling = true }
        let settle: Double = scenario.hasSuffix("untouched") ? 33 : 2.5
        DispatchQueue.main.asyncAfter(deadline: .now() + settle) {
            let onscreen: String = {
                guard let w = window,
                      let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(w.windowNumber)) as? [[String: Any]],
                      let first = info.first else { return "no window" }
                return (first[kCGWindowIsOnscreen as String] as? Bool) == true ? "on screen" : "NOT on screen"
            }()
            let c0 = cpuSeconds(), w0 = Date(), f0 = LiquidStats.framesDrawn
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                let wall = Date().timeIntervalSince(w0)
                let pct = (cpuSeconds() - c0) / wall * 100
                print(String(format: "%-16@ %5.1f%% CPU   %5.1f canvas frames/s   [%@]", scenario as NSString, pct,
                             Double(LiquidStats.framesDrawn - f0) / wall, onscreen as NSString))
                if model.isRunning { model.stop() }
                NSApp.terminate(nil)
            }
        }
    }

    final class BenchClock: ObservableObject { @Published var t: Double = 0 }

    struct BenchView: View {
        @ObservedObject var clock: BenchClock
        var cells: [LiquidCell]
        var motion: LiquidMotion
        var compact: Bool
        var body: some View {
            LiquidCanvas(cells: cells, motion: motion, paused: false, reduceMotion: false, t: clock.t,
                         labels: { SnapshotRenderer.benchLabel($0, $1, compact: compact) })
        }
    }

    @ViewBuilder
    static func benchLabel(_ cell: LiquidCell, _ submerged: Bool, compact: Bool) -> some View {
        if ProcessInfo.processInfo.environment["BENCH_NOLABELS"] != nil {
            EmptyView()
        } else if compact {
            Text("\(cell.key.day)").font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(submerged ? Theme.onLiquid : .primary)
        } else {
            DayTileLabels(info: DayTileInfo(day: cell.key, seconds: cell.seconds, pending: 0, goalSeconds: 8 * 3600,
                                            isToday: false, isFuture: false, live: false, compact: false),
                          submerged: submerged)
        }
    }

    /// The menu bar glyph + text in its main states, drawn with the real `StatusItemController.icon`.
    private static func renderStatusItems(to url: URL) {
        let states: [(String, Double, Bool, Bool)] = [("0:00  stopped, empty", 0, false, false),
                                                       ("4:45  running, 59% of goal", 0.59, true, false),
                                                       ("8:10  goal reached", 1, false, false),
                                                       ("2:00  interrupted session pending", 0.25, false, true)]
        let size = NSSize(width: 360, height: CGFloat(states.count) * 34 + 16)
        let image = NSImage(size: size, flipped: true) { _ in
            NSColor(white: 0.93, alpha: 1).setFill()
            NSRect(origin: .zero, size: size).fill()
            for (i, state) in states.enumerated() {
                let y = 8 + CGFloat(i) * 34
                NSColor(white: 0.98, alpha: 1).setFill()
                NSBezierPath(roundedRect: NSRect(x: 8, y: y, width: size.width - 16, height: 28), xRadius: 6, yRadius: 6).fill()
                let icon = StatusItemController.icon(progress: state.1, running: state.2, pending: state.3)
                icon.draw(in: NSRect(x: 16, y: y + 6.5, width: 15, height: 15))
                let parts = state.0.split(separator: " ", maxSplits: 1)
                (String(parts[0]) as NSString).draw(at: NSPoint(x: 36, y: y + 5), withAttributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: state.2 ? .semibold : .regular), .foregroundColor: NSColor.black])
                (String(parts[1]).trimmingCharacters(in: .whitespaces) as NSString).draw(at: NSPoint(x: 100, y: y + 6), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.darkGray])
            }
            return true
        }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }

    private static func render<V: View>(_ view: V, size: CGSize, scheme: ColorScheme, to url: URL) {
        let content = view
            .frame(width: size.width, height: size.height)
            .background(Theme.windowBackground(scheme))
            .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        var image: NSImage?
        appearance?.performAsCurrentDrawingAppearance { image = renderer.nsImage }
        guard let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            print("Failed to render \(url.lastPathComponent)")
            return
        }
        try? png.write(to: url)
    }
}

/// A row of tiles demonstrating the fill scale: 0h, 4h30, 9h (half), 18h (full), 19h (overflow), 23h.
private struct TileScale: View {
    var slosh = false
    @Environment(\.colorScheme) private var scheme

    private func makeMotion(_ key: DayKey) -> LiquidMotion {
        let motion = LiquidMotion()
        if slosh { motion.slosh(key, t: Date().timeIntervalSinceReferenceDate + 0.05) }
        return motion
    }
    var body: some View {
        let hours: [Double] = [0, 4.5, 9, 18, 19, 23]
        HStack(spacing: 14) {
            ForEach(Array(hours.enumerated()), id: \.offset) { i, h in
                VStack(spacing: 6) {
                    ZStack(alignment: .topLeading) {
                        GeometryReader { geo in
                            let key = DayKey(year: 2026, month: 1, day: i + 1)
                            let motion = makeMotion(key)
                            LiquidLayer(cells: [LiquidCell(key: key,
                                                           rect: CGRect(origin: .zero, size: geo.size).insetBy(dx: 4, dy: 4),
                                                           cornerRadius: 14, seconds: h * 3600, dimmed: false, live: false)],
                                        motion: motion,
                                        cadence: LiquidCadence(reduceMotion: false, windowState: .key, windowVisible: true, compact: false)) { cell, submerged in
                                DayTileLabels(info: DayTileInfo(day: key, seconds: h * 3600, pending: 0, goalSeconds: 8 * 3600,
                                                                isToday: false, isFuture: false, live: false, compact: false),
                                              submerged: submerged)
                            }
                        }
                    }
                    .frame(width: 104, height: 140)
                    Text(h == 0 ? "empty" : h == 9 ? "half" : h == 18 ? "full" : h > 18 ? "overflow" : "")
                        .font(.system(size: 11)).foregroundStyle(Theme.secondaryText(scheme))
                }
            }
        }
        .padding(20)
    }
}
