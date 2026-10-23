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
            // Previous month (contains the 18h+ overflow day in the demo data).
            render(CalendarRootView(initialMonth: MonthKey(today.adding(days: -16, calendar: cal)), mode: .month, snapshotNow: now).environment(model),
                   size: CGSize(width: 1060, height: 800), scheme: .light, to: outputDirectory.appendingPathComponent("month-overflow-light.png"))
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
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let hours: [Double] = [0, 4.5, 9, 18, 19, 23]
        HStack(spacing: 14) {
            ForEach(Array(hours.enumerated()), id: \.offset) { i, h in
                VStack(spacing: 6) {
                    ZStack(alignment: .topLeading) {
                        GeometryReader { geo in
                            LiquidLayer(cells: [LiquidCell(key: DayKey(year: 2026, month: 1, day: i + 1),
                                                           rect: CGRect(origin: .zero, size: geo.size).insetBy(dx: 4, dy: 4),
                                                           cornerRadius: 14, seconds: h * 3600, dimmed: false, live: false)],
                                        motion: LiquidMotion(),
                                        cadence: LiquidCadence(reduceMotion: false, windowState: .key, windowVisible: true, compact: false))
                        }
                        VStack(alignment: .leading) {
                            Text("\(i + 1)").font(.system(size: 16, weight: .semibold, design: .rounded))
                                .foregroundStyle(h / 18 > 0.72 ? Theme.onLiquid : .primary)
                            Spacer()
                            Text(DurationFormat.short(h * 3600)).font(.system(size: 13.5, weight: .semibold, design: .rounded))
                                .foregroundStyle(h / 18 > 0.2 ? Theme.onLiquid : .primary)
                        }
                        .padding(14)
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
