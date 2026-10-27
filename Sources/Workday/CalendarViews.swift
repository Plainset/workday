import SwiftUI
import WorkdayCore

enum CalendarMode: Hashable { case month, year }

/// Reduce Motion aware animation helper: springs and slides only when motion is welcome.
private func motionAnimation(_ reduce: Bool, _ animation: Animation = .snappy(duration: 0.35)) -> Animation {
    reduce ? .easeInOut(duration: 0.15) : animation
}

/// The main calendar window: month-first with an optional twelve-month overview.
struct CalendarRootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.forceReducedMotion) private var forceReducedMotion
    private var reduceMotion: Bool { systemReduceMotion || forceReducedMotion }
    @State private var month: MonthKey
    @State private var mode: CalendarMode = .month
    @State private var editingDay: DayKey?
    @State private var direction: Int = 0
    var snapshotNow: Date? = nil

    init(initialMonth: MonthKey? = nil, mode: CalendarMode = .month, snapshotNow: Date? = nil) {
        _month = State(initialValue: initialMonth ?? MonthKey(Date(), calendar: .autoupdatingCurrent))
        _mode = State(initialValue: mode)
        self.snapshotNow = snapshotNow
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 28)
                .padding(.top, 34)
                .padding(.bottom, 10)
            SummaryStrip(month: month, mode: mode)
                .padding(.horizontal, 28)
                .padding(.bottom, 14)
            Group {
                if let error = model.errorMessage {
                    ErrorBanner(message: error) { model.errorMessage = nil }
                }
                if model.ledger.hasPendingRecovery {
                    RecoveryNotice()
                }
                BackupFailureNotice()
                if model.ledger.sessions.isEmpty {
                    EmptyCalendarHint()
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 10)
            Group {
                switch mode {
                case .month:
                    MonthGridView(month: month, onOpen: { editingDay = $0 })
                        .id(month)
                        .transition(reduceMotion
                                    ? .opacity
                                    : .asymmetric(insertion: .move(edge: direction >= 0 ? .trailing : .leading).combined(with: .opacity),
                                                  removal: .opacity))
                case .year:
                    YearOverviewView(year: month.year,
                                     onOpenDay: { editingDay = $0 },
                                     onOpenMonth: { m in
                                         withAnimation(motionAnimation(reduceMotion)) { month = m; mode = .month }
                                     })
                        .id(month.year)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 22)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        .background(Theme.windowBackground(scheme))
        .sheet(item: $editingDay) { day in
            DayEditorView(day: day) { editingDay = nil }
                .environment(model)
        }
        .onChange(of: model.requestedDay) { _, day in
            guard let day else { return }
            month = MonthKey(day)
            mode = .month
            editingDay = day
            model.requestedDay = nil
        }
        .onAppear {
            if snapshotNow == nil { month = MonthKey(model.today) }
        }
    }

    private var title: String {
        switch mode {
        case .month:
            return DateFormatter.make("MMMMyyyy", calendar: model.calendar).string(from: month.firstDay.noon(in: model.calendar))
        case .year:
            return String(month.year)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .minimumScaleFactor(0.7)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            SegmentedSwitch(options: [(CalendarMode.month, "Month"), (CalendarMode.year, "Year")], selection: $mode)
            HStack(spacing: 6) {
                Button { navigate(-1) } label: { Image(systemName: "chevron.left").frame(width: 14) }
                    .buttonStyle(PillButtonStyle(compact: true))
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                    .accessibilityLabel(mode == .month ? "Previous month" : "Previous year")
                Button("Today") { goToday() }
                    .buttonStyle(PillButtonStyle(compact: true))
                    .keyboardShortcut("t", modifiers: .command)
                Button { navigate(1) } label: { Image(systemName: "chevron.right").frame(width: 14) }
                    .buttonStyle(PillButtonStyle(compact: true))
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                    .accessibilityLabel(mode == .month ? "Next month" : "Next year")
            }
            Button {
                model.isRunning ? model.stop() : model.start()
            } label: {
                Label(model.isRunning ? "Stop Work" : "Start Work", systemImage: model.isRunning ? "stop.fill" : "play.fill")
            }
            .buttonStyle(PillButtonStyle(kind: model.isRunning ? .secondary : .primary, compact: true))
            .accessibilityHint(model.isRunning ? "Stops the timer now and records the session" : "Starts the work timer now")
        }
        .background(alignment: .topLeading) {
            // Hidden shortcuts for switching views.
            HStack {
                Button("") { mode = .month }.keyboardShortcut("1", modifiers: .command)
                Button("") { mode = .year }.keyboardShortcut("2", modifiers: .command)
            }
            .opacity(0)
            .accessibilityHidden(true)
        }
    }

    private func navigate(_ step: Int) {
        direction = step
        withAnimation(motionAnimation(reduceMotion)) {
            month = mode == .month ? month.adding(months: step) : month.adding(months: 12 * step)
        }
    }

    private func goToday() {
        let target = MonthKey(model.today)
        direction = target < month ? -1 : 1
        withAnimation(motionAnimation(reduceMotion)) { month = target }
    }
}

struct ErrorBanner: View {
    var message: String
    var dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
            Text(message).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Dismiss", action: dismiss).buttonStyle(PillButtonStyle(kind: .plain, compact: true))
        }
        .padding(10)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Shown until the first session exists.
struct EmptyCalendarHint: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "drop.fill").foregroundStyle(Theme.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("No work recorded yet").font(.system(size: 13, weight: .semibold))
                Text("Press Start Work here or in the menu bar. Each day fills with liquid as you work — full at 18 hours. Click a day to add time you forgot to track.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(12)
        .background(Theme.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Minimal summary: month (or year) total, goal days, streak and today's goal progress.
struct SummaryStrip: View {
    var month: MonthKey
    var mode: CalendarMode
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ledger = model.ledger
        let now = model.displayNow
        let total: TimeInterval
        let goalDays: Int
        if mode == .month {
            let s = ledger.monthSummary(month, now: now)
            total = s.totalSeconds
            goalDays = s.goalDays
        } else {
            let summaries = (1...12).map { ledger.monthSummary(MonthKey(year: month.year, month: $0), now: now) }
            total = summaries.reduce(0) { $0 + $1.totalSeconds }
            goalDays = summaries.reduce(0) { $0 + $1.goalDays }
        }
        let streak = ledger.streak(now: now)
        let todayTotal = model.displayTodayTotal

        return HStack(spacing: 22) {
            stat("This week", DurationFormat.short(ledger.weekTotal(now: now)))
            stat(mode == .month ? "This month" : "This year", DurationFormat.short(total))
            stat("Goal days", "\(goalDays)")
            stat("Streak", streak == 0 ? "—" : "\(streak) day\(streak == 1 ? "" : "s")", icon: streak > 0 ? "flame.fill" : nil)
            stat("Daily goal", DurationFormat.goal(minutes: ledger.settings.dailyGoalMinutes))
            Spacer(minLength: 10)
            VStack(alignment: .trailing, spacing: 5) {
                Text("Today \(DurationFormat.short(todayTotal)) of \(DurationFormat.goal(minutes: ledger.settings.dailyGoalMinutes))")
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                ProgressLine(progress: model.displayGoalProgress, height: 5)
                    .frame(width: 180)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func stat(_ label: String, _ value: String, icon: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10.5, weight: .semibold))
                .textCase(.uppercase)
                .foregroundStyle(Theme.secondaryText(scheme))
            HStack(spacing: 4) {
                if let icon { Image(systemName: icon).foregroundStyle(Theme.orange).font(.system(size: 12)) }
                Text(value)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Month grid

struct MonthGridView: View {
    var month: MonthKey
    var onOpen: (DayKey) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.forceReducedMotion) private var forceReducedMotion
    private var reduceMotion: Bool { systemReduceMotion || forceReducedMotion }
    @Environment(\.controlActiveState) private var activeState
    @State private var motion = LiquidMotion()
    @State private var focusedDay: DayKey?
    @State private var hovered: DayKey?
    @FocusState private var gridFocused: Bool

    private let spacing: CGFloat = 9

    var body: some View {
        let cal = model.calendar
        let cells = MonthGridLayout.cells(for: month, calendar: cal)
        let rows = cells.count / 7
        let ledger = model.ledger
        let now = model.displayNow
        let today = model.today
        let activeDays: Set<DayKey> = {
            guard let a = ledger.activeSession else { return [] }
            return Set(TimeMath.slices(start: a.start, end: max(now, a.start.addingTimeInterval(1)), calendar: cal).map(\.day))
        }()
        let totals = ledger.totals(for: cells.map(\.day), now: now)

        VStack(spacing: 8) {
            HStack(spacing: spacing) {
                ForEach(Array(MonthGridLayout.weekdaySymbols(calendar: cal).enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(Theme.secondaryText(scheme))
                        .frame(maxWidth: .infinity)
                }
            }
            .accessibilityHidden(true)

            GeometryReader { geo in
                let cellW = (geo.size.width - spacing * 6) / 7
                let cellH = (geo.size.height - spacing * CGFloat(rows - 1)) / CGFloat(rows)
                let rect: (MonthGridCell) -> CGRect = { c in
                    CGRect(x: CGFloat(c.column) * (cellW + spacing), y: CGFloat(c.row) * (cellH + spacing), width: cellW, height: cellH)
                }
                let grow: CGFloat = reduceMotion ? 0 : 2
                let liquidCells = cells.map { c in
                    LiquidCell(key: c.day, rect: rect(c).insetBy(dx: hovered == c.day ? -grow : 0, dy: hovered == c.day ? -grow : 0),
                               cornerRadius: min(16, cellW * 0.14), seconds: totals[c.day] ?? 0,
                               dimmed: !c.isInDisplayedMonth, live: activeDays.contains(c.day))
                }
                let info: (DayKey) -> DayTileInfo = { day in
                    DayTileInfo(day: day, seconds: totals[day] ?? 0, pending: ledger.pendingSeconds(for: day),
                                goalSeconds: ledger.settings.dailyGoalSeconds, isToday: day == today, isFuture: day > today,
                                live: activeDays.contains(day), compact: cellH < 70)
                }
                let cadence = LiquidCadence(reduceMotion: reduceMotion, windowState: activeState,
                                            windowVisible: model.calendarVisible || AppDelegate.shared == nil, compact: false)
                ZStack(alignment: .topLeading) {
                    // Idle tiles and the live tile are separate layers, so a running timer only redraws
                    // its own tile at the live rate.
                    LiquidLayer(cells: liquidCells.filter { !$0.live }, motion: motion, cadence: cadence) { cell, submerged in
                        DayTileLabels(info: info(cell.key), submerged: submerged)
                    }
                    LiquidLayer(cells: liquidCells.filter { $0.live }, motion: motion, cadence: cadence) { cell, submerged in
                        DayTileLabels(info: info(cell.key), submerged: submerged)
                    }
                    ForEach(cells) { c in
                        let r = rect(c)
                        DayTile(cell: c, info: info(c.day),
                                focused: gridFocused && focusedDay == c.day,
                                size: r.size,
                                open: { onOpen(c.day) })
                            .frame(width: r.width, height: r.height)
                            .offset(x: r.minX, y: r.minY)
                            .onHover { inside in
                                if inside {
                                    hovered = c.day
                                    if !reduceMotion { motion.slosh(c.day, t: Date().timeIntervalSinceReferenceDate) }
                                } else if hovered == c.day {
                                    hovered = nil
                                }
                            }
                    }
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hovered)
            }
        }
        .onContinuousHover { _ in motion.touch() }
        .focusable()
        .focused($gridFocused)
        .focusEffectDisabled()
        .onMoveCommand { direction in
            motion.touch()
            let current = focusedDay ?? (MonthKey(today) == month ? today : month.firstDay)
            let next = current.adding(days: gridStep(direction), calendar: cal)
            if cells.contains(where: { $0.day == next && $0.isInDisplayedMonth }) {
                focusedDay = next
                if !reduceMotion { motion.slosh(next, t: Date().timeIntervalSinceReferenceDate) }
            }
        }
        .onKeyPress(.return) {
            onOpen(focusedDay ?? today)
            return .handled
        }
        .onKeyPress(.space) {
            onOpen(focusedDay ?? today)
            return .handled
        }
        .onAppear {
            focusedDay = MonthKey(today) == month ? today : month.firstDay
            gridFocused = true
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(DateFormatter.make("MMMMyyyy", calendar: cal).string(from: month.firstDay.noon(in: cal)))
    }
}

func gridStep(_ direction: MoveCommandDirection) -> Int {
    switch direction {
    case .left: return -1
    case .right: return 1
    case .up: return -7
    case .down: return 7
    @unknown default: return 0
    }
}

/// Everything a day tile shows, computed once from the ledger.
struct DayTileInfo {
    var day: DayKey
    var seconds: TimeInterval
    var pending: TimeInterval
    var goalSeconds: TimeInterval
    var isToday: Bool
    var isFuture: Bool
    var live: Bool
    var compact: Bool

    var metGoal: Bool { goalSeconds > 0 && seconds >= goalSeconds }
}

/// The visible labels of a day tile. Rendered into the liquid Canvas twice: normal colours
/// above the surface and `submerged` (dark on orange) below it.
struct DayTileLabels: View {
    var info: DayTileInfo
    var submerged: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let primary: Color = submerged ? Theme.onLiquid : .primary
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 4) {
                Text("\(info.day.day)")
                    .font(.system(size: info.compact ? 13 : 16, weight: info.isToday ? .heavy : .semibold, design: .rounded))
                    .foregroundStyle(submerged ? Theme.onLiquid : (info.isToday ? Theme.orangeDeep : .primary))
                    .padding(.horizontal, info.isToday ? 6 : 0)
                    .padding(.vertical, info.isToday ? 1 : 0)
                    .background {
                        if info.isToday {
                            Capsule().fill((submerged ? Color.white : Theme.orange).opacity(submerged ? 0.35 : 0.16))
                        }
                    }
                Spacer(minLength: 0)
                if info.live {
                    Circle().fill(submerged ? Theme.onLiquid : Theme.orange).frame(width: 7, height: 7)
                        .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 1))
                        .padding(.top, 4)
                }
                if info.metGoal {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: info.compact ? 10 : 12))
                        .foregroundStyle(submerged ? Theme.onLiquid.opacity(0.8) : Theme.orange)
                }
            }
            Spacer(minLength: 0)
            if info.pending > 0 {
                Label(DurationFormat.short(info.pending), systemImage: "questionmark.circle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(submerged ? Theme.onLiquid : .red)
                    .labelStyle(.titleAndIcon)
            }
            HStack(alignment: .lastTextBaseline, spacing: 3) {
                Text(DurationFormat.short(info.seconds))
                    .font(.system(size: info.compact ? 11.5 : 13.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .foregroundStyle(info.seconds > 0 || submerged ? primary
                                     : Theme.secondaryText(scheme).opacity(info.isFuture ? 0.6 : 1))
                if LiquidScale.isOverflowing(seconds: info.seconds) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(primary)
                }
            }
        }
        .padding(.horizontal, info.compact ? 7 : 10)
        .padding(.vertical, info.compact ? 6 : 9)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Interaction, rings and accessibility for one day; the visible labels are drawn in the liquid Canvas.
struct DayTile: View {
    var cell: MonthGridCell
    var info: DayTileInfo
    var focused: Bool
    var size: CGSize
    var open: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        let corner = min(16, size.width * 0.14)
        Button(action: open) {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .overlay {
            if info.isToday {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(Theme.orange, lineWidth: 2)
            }
        }
        .overlay {
            if focused {
                RoundedRectangle(cornerRadius: corner + 3, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2.5)
                    .padding(-4)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(DayAccessibility.label(day: info.day, seconds: info.seconds, pending: info.pending,
                                                   isToday: info.isToday, live: info.live, metGoal: info.metGoal,
                                                   calendar: model.calendar))
        .accessibilityHint("Opens the session editor for this day")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { open() }
        .help("\(DateFormatter.make("EEEEdMMMMyyyy", calendar: model.calendar).string(from: cell.day.noon(in: model.calendar))) — \(DurationFormat.short(info.seconds))")
    }
}

// MARK: - Year overview

/// Shared geometry so the liquid canvas and the day buttons agree on every mini tile.
enum MiniMonthGeometry {
    static let gap: CGFloat = 3
    static let padding: CGFloat = 12
    static let headerHeight: CGFloat = 18
    static let weekdayHeight: CGFloat = 11
    static let spacing: CGFloat = 5
    /// Smallest tile on which a two-digit day number is legible.
    static let minimumSide: CGFloat = 14
    static let panelGap: CGFloat = 18

    static var chromeHeight: CGFloat { padding * 2 + headerHeight + spacing + weekdayHeight + spacing }

    /// The day-grid area inside a mini month panel of `size`, in panel coordinates.
    static func gridFrame(panel size: CGSize) -> CGRect {
        let top = padding + headerHeight + spacing + weekdayHeight + spacing
        return CGRect(x: padding, y: top, width: max(0, size.width - padding * 2), height: max(0, size.height - top - padding))
    }

    static func side(in size: CGSize) -> CGFloat {
        max(1, min((size.width - gap * 6) / 7, (size.height - gap * 5) / 6))
    }

    /// Rect of a cell relative to the grid area's origin.
    static func rect(_ c: MonthGridCell, in size: CGSize) -> CGRect {
        let side = side(in: size)
        let originX = (size.width - (side * 7 + gap * 6)) / 2
        return CGRect(x: originX + CGFloat(c.column) * (side + gap), y: CGFloat(c.row) * (side + gap), width: side, height: side)
    }

    struct Layout: Equatable {
        var columns: Int
        var panel: CGSize
        var contentHeight: CGFloat
        var scrolls: Bool
        var side: CGFloat
    }

    /// Picks the arrangement (6×2, 4×3, 3×4 or 2×6) that gives the largest tiles. If even the best one
    /// would make tiles smaller than `minimumSide`, panels get their natural height and the year scrolls.
    static func layout(for size: CGSize) -> Layout {
        var best: Layout?
        for columns in [6, 4, 3, 2] {
            let rows = 12 / columns
            let w = (size.width - panelGap * CGFloat(columns - 1)) / CGFloat(columns)
            let h = (size.height - panelGap * CGFloat(rows - 1)) / CGFloat(rows)
            let grid = gridFrame(panel: CGSize(width: w, height: h)).size
            let side = Self.side(in: grid)
            if side > (best?.side ?? 0) {
                best = Layout(columns: columns, panel: CGSize(width: w, height: h), contentHeight: size.height, scrolls: false, side: side)
            }
        }
        if let best, best.side >= minimumSide { return best }
        // Scroll: choose the column count whose width gives the largest tile (capped for balance).
        var scrolled: Layout?
        for columns in [4, 3, 2] {
            let rows = 12 / columns
            let w = (size.width - panelGap * CGFloat(columns - 1)) / CGFloat(columns)
            let side = min(26, (w - padding * 2 - gap * 6) / 7)
            if side > (scrolled?.side ?? 0) {
                let h = chromeHeight + side * 6 + gap * 5
                scrolled = Layout(columns: columns, panel: CGSize(width: w, height: h),
                                  contentHeight: h * CGFloat(rows) + panelGap * CGFloat(rows - 1), scrolls: true, side: side)
            }
        }
        return scrolled ?? best!
    }
}

struct YearOverviewView: View {
    var year: Int
    var onOpenDay: (DayKey) -> Void
    var onOpenMonth: (MonthKey) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.forceReducedMotion) private var forceReducedMotion
    private var reduceMotion: Bool { systemReduceMotion || forceReducedMotion }
    @Environment(\.controlActiveState) private var activeState
    @State private var hovered: DayKey?
    @State private var focusedDay: DayKey?
    @State private var motion = LiquidMotion()
    @FocusState private var focused: Bool

    var body: some View {
        let cal = model.calendar
        let now = model.displayNow
        let today = model.today
        let months = (1...12).map { MonthKey(year: year, month: $0) }
        let days = months.flatMap { $0.days(calendar: cal) }
        let totals = model.ledger.totals(for: days, now: now)
        // A day under the pointer wins; otherwise the keyboard-focused day.
        let readoutDay = hovered ?? (focused ? focusedDay : nil)

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: hovered == nil && focused ? "keyboard" : "hand.point.up.left").foregroundStyle(Theme.secondaryText(scheme))
                if let day = readoutDay {
                    Text(DateFormatter.make("EEEEdMMMMyyyy", calendar: cal).string(from: day.noon(in: cal)))
                        .font(.system(size: 12, weight: .semibold))
                    Text(DurationFormat.short(totals[day] ?? 0))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Theme.orangeDeep)
                } else {
                    Text("Hover over a day (or use the arrow keys) to see its exact hours · click or press Return to edit · click a month name to open it")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText(scheme))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            .frame(height: 18)
            .padding(.horizontal, 6)
            .accessibilityElement(children: .combine)

            GeometryReader { geo in
                let layout = MiniMonthGeometry.layout(for: geo.size)
                let content = yearContent(layout: layout, months: months, totals: totals, today: today, cal: cal)
                if layout.scrolls && !LiquidMotion.settleInstantly {
                    ScrollViewReader { proxy in
                        ScrollView(.vertical) {
                            content
                                .frame(width: geo.size.width, height: layout.contentHeight, alignment: .topLeading)
                                .background(alignment: .topLeading) {
                                    // Invisible per-month anchors so keyboard focus can scroll into view.
                                    ZStack(alignment: .topLeading) {
                                        ForEach(Array(months.enumerated()), id: \.offset) { i, m in
                                            Color.clear
                                                .frame(width: layout.panel.width, height: layout.panel.height)
                                                .id(m)
                                                .padding(.leading, CGFloat(i % layout.columns) * (layout.panel.width + MiniMonthGeometry.panelGap))
                                                .padding(.top, CGFloat(i / layout.columns) * (layout.panel.height + MiniMonthGeometry.panelGap))
                                        }
                                    }
                                }
                        }
                        .onChange(of: focusedDay) { _, day in
                            guard let day, focused, hovered == nil else { return }
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { proxy.scrollTo(MonthKey(day)) }
                        }
                    }
                } else {
                    // (Offscreen snapshots can't render AppKit scroll views; they show the top of the content.)
                    content.frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading).clipped()
                }
            }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onMoveCommand { direction in
            hovered = nil
            let current = focusedDay ?? (today.year == year ? today : DayKey(year: year, month: 1, day: 1))
            let next = current.adding(days: gridStep(direction), calendar: cal)
            if next.year == year { focusedDay = next }
        }
        .onKeyPress(.return) {
            if let day = focusedDay { onOpenDay(day) }
            return .handled
        }
        .onKeyPress(.space) {
            if let day = focusedDay { onOpenDay(day) }
            return .handled
        }
        .onAppear {
            focusedDay = today.year == year ? today : DayKey(year: year, month: 1, day: 1)
            focused = true
        }
    }

    @ViewBuilder
    private func yearContent(layout: MiniMonthGeometry.Layout, months: [MonthKey], totals: [DayKey: TimeInterval],
                             today: DayKey, cal: Calendar) -> some View {
        let gap = MiniMonthGeometry.panelGap
        let w = layout.panel.width, h = layout.panel.height
        let origin: (Int) -> CGPoint = { i in CGPoint(x: CGFloat(i % layout.columns) * (w + gap), y: CGFloat(i / layout.columns) * (h + gap)) }
        let showNumbers = layout.side >= MiniMonthGeometry.minimumSide

        // One canvas and one timeline for all 365 tiles, numbers included.
        let liquid: [LiquidCell] = months.enumerated().flatMap { i, m -> [LiquidCell] in
            let frame = MiniMonthGeometry.gridFrame(panel: layout.panel).offsetBy(dx: origin(i).x, dy: origin(i).y)
            return MonthGridLayout.cells(for: m, calendar: cal, fixedSixRows: true).filter(\.isInDisplayedMonth).map { c in
                let r = MiniMonthGeometry.rect(c, in: frame.size).offsetBy(dx: frame.minX, dy: frame.minY)
                return LiquidCell(key: c.day, rect: r, cornerRadius: r.width * 0.22, seconds: totals[c.day] ?? 0,
                                  dimmed: false, live: false, compact: true)
            }
        }

        ZStack(alignment: .topLeading) {
            ForEach(Array(months.enumerated()), id: \.offset) { i, _ in
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Theme.panelBackground(scheme).opacity(scheme == .dark ? 0.6 : 0.85))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.tileBorder(scheme)))
                    .frame(width: w, height: h)
                    .offset(x: origin(i).x, y: origin(i).y)
            }
            LiquidLayer(cells: liquid, motion: motion,
                        cadence: LiquidCadence(reduceMotion: reduceMotion, windowState: activeState,
                                               windowVisible: model.calendarVisible || AppDelegate.shared == nil,
                                               compact: true))
            .allowsHitTesting(false)
            ForEach(Array(months.enumerated()), id: \.offset) { i, m in
                MiniMonthView(month: m, totals: totals, today: today, showNumbers: showNumbers,
                              hovered: $hovered,
                              focusedDay: focused ? focusedDay : nil,
                              onOpenDay: onOpenDay, onOpenMonth: onOpenMonth,
                              onHoverDay: { day in if !reduceMotion { motion.slosh(day, t: Date().timeIntervalSinceReferenceDate) } })
                    .frame(width: w, height: h)
                    .offset(x: origin(i).x, y: origin(i).y)
            }
        }
    }
}

/// Header, weekday row, day numbers and interaction for one mini month. Kept deliberately light:
/// numbers are one static Canvas (split at each tile's waterline), hover/click is one surface that maps
/// the pointer to a day, and VoiceOver gets one accessibility child per day. The animated liquid is drawn
/// by the year view's shared Canvas underneath.
struct MiniMonthView: View {
    var month: MonthKey
    var totals: [DayKey: TimeInterval]
    var today: DayKey
    var showNumbers: Bool
    @Binding var hovered: DayKey?
    var focusedDay: DayKey?
    var onOpenDay: (DayKey) -> Void
    var onOpenMonth: (MonthKey) -> Void
    var onHoverDay: (DayKey) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let cal = model.calendar
        let cells = MonthGridLayout.cells(for: month, calendar: cal, fixedSixRows: true)
        let inMonth = cells.filter(\.isInDisplayedMonth)
        let monthTotal = inMonth.reduce(0) { $0 + (totals[$1.day] ?? 0) }
        let name = DateFormatter.make("MMMM", calendar: cal).string(from: month.firstDay.noon(in: cal))

        VStack(alignment: .leading, spacing: MiniMonthGeometry.spacing) {
            Button { onOpenMonth(month) } label: {
                HStack(alignment: .firstTextBaseline) {
                    Text(name)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(MonthKey(today) == month ? Theme.orangeDeep : .primary)
                    Spacer()
                    Text(DurationFormat.short(monthTotal))
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Theme.secondaryText(scheme))
                }
                .lineLimit(1)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(height: MiniMonthGeometry.headerHeight)
            .accessibilityLabel("\(name) \(month.year), \(DurationFormat.spoken(monthTotal)). Opens month view.")

            HStack(spacing: 3) {
                ForEach(Array(MonthGridLayout.weekdaySymbols(calendar: cal, veryShort: true).enumerated()), id: \.offset) { _, s in
                    Text(s).font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(Theme.secondaryText(scheme))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: MiniMonthGeometry.weekdayHeight)
            .accessibilityHidden(true)

            GeometryReader { geo in
                let size = geo.size
                let side = MiniMonthGeometry.side(in: size)
                let rects = inMonth.map { ($0.day, MiniMonthGeometry.rect($0, in: size)) }
                let dayAt: (CGPoint) -> DayKey? = { p in rects.first { $0.1.insetBy(dx: -1.5, dy: -1.5).contains(p) }?.0 }
                Canvas { context, _ in
                    let corner = side * 0.22
                    for (day, r) in rects {
                        let seconds = totals[day] ?? 0
                        let isToday = day == today
                        if isToday {
                            context.stroke(Path(roundedRect: r.insetBy(dx: 0.75, dy: 0.75), cornerRadius: corner, style: .continuous),
                                           with: .color(Theme.orange), lineWidth: 1.5)
                        }
                        if focusedDay == day {
                            context.stroke(Path(roundedRect: r.insetBy(dx: -2, dy: -2), cornerRadius: corner + 2, style: .continuous),
                                           with: .color(.accentColor), lineWidth: 2)
                        }
                        guard showNumbers else { continue }
                        let font = Font.system(size: min(11, max(8, side * 0.4)), weight: isToday ? .heavy : .semibold, design: .rounded)
                        let normal = context.resolve(Text("\(day.day)").font(font)
                            .foregroundStyle(isToday ? Theme.orangeDeep : Color.primary.opacity(0.8)))
                        let fraction = LiquidScale.fillFraction(seconds: seconds)
                        let waterline = r.maxY - r.height * (fraction >= 0.999 ? 1 : fraction)
                        var above = context
                        above.clip(to: Path(CGRect(x: r.minX, y: r.minY, width: r.width, height: max(0, waterline - r.minY))))
                        above.draw(normal, at: CGPoint(x: r.midX, y: r.midY))
                        if fraction > 0 {
                            let submerged = context.resolve(Text("\(day.day)").font(font).foregroundStyle(Theme.onLiquid))
                            var below = context
                            below.clip(to: Path(CGRect(x: r.minX, y: waterline, width: r.width, height: r.maxY - waterline)))
                            below.draw(submerged, at: CGPoint(x: r.midX, y: r.midY))
                        }
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p):
                        let day = dayAt(p)
                        if day != hovered {
                            hovered = day
                            if let day { onHoverDay(day) }
                        }
                    case .ended:
                        if let h = hovered, inMonth.contains(where: { $0.day == h }) { hovered = nil }
                    }
                }
                .gesture(SpatialTapGesture().onEnded { value in
                    if let day = dayAt(value.location) { onOpenDay(day) }
                })
                .help(hovered.flatMap { h in inMonth.contains { $0.day == h } ? "\(DateFormatter.make("EEEdMMM", calendar: cal).string(from: h.noon(in: cal))) — \(DurationFormat.short(totals[h] ?? 0))" : nil } ?? "")
                .accessibilityElement(children: .contain)
                .accessibilityChildren {
                    ForEach(rects, id: \.0) { day, r in
                        let seconds = totals[day] ?? 0
                        Rectangle()
                            .frame(width: r.width, height: r.height)
                            .position(x: r.midX, y: r.midY)
                            .accessibilityLabel(DayAccessibility.label(day: day, seconds: seconds, pending: model.ledger.pendingSeconds(for: day),
                                                                       isToday: day == today, live: false,
                                                                       metGoal: seconds >= model.ledger.settings.dailyGoalSeconds,
                                                                       calendar: cal))
                            .accessibilityHint("Opens the session editor for this day")
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { onOpenDay(day) }
                    }
                }
            }
        }
        .padding(MiniMonthGeometry.padding)
    }
}
