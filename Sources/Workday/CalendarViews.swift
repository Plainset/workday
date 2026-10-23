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
            stat(mode == .month ? "This month" : "This year", DurationFormat.short(total))
            stat("Goal days", "\(goalDays)")
            stat("Streak", streak == 0 ? "—" : "\(streak) day\(streak == 1 ? "" : "s")", icon: streak > 0 ? "flame.fill" : nil)
            stat("Daily goal", DurationFormat.goal(minutes: ledger.settings.dailyGoalMinutes))
            Spacer(minLength: 10)
            VStack(alignment: .trailing, spacing: 5) {
                Text("Today \(DurationFormat.short(todayTotal)) of \(DurationFormat.goal(minutes: ledger.settings.dailyGoalMinutes))")
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
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

/// Renders `content` twice: in its normal colours above the waterline and in high-contrast
/// on-liquid colours below it, so labels stay legible wherever the liquid surface crosses them.
struct WaterlineSplit<Content: View>: View {
    var fraction: Double
    var height: CGFloat
    var animate: Bool
    @ViewBuilder var content: (_ submerged: Bool) -> Content

    var body: some View {
        let waterline = fraction >= 0.999 ? height : height * fraction
        ZStack {
            content(false)
                .mask(alignment: .top) { Rectangle().frame(height: max(0, height - waterline)) }
            content(true)
                .mask(alignment: .bottom) { Rectangle().frame(height: waterline) }
        }
        .animation(animate ? .easeOut(duration: LiquidMotion.fillDuration) : nil, value: fraction)
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
                ZStack(alignment: .topLeading) {
                    LiquidLayer(cells: liquidCells, motion: motion,
                                cadence: LiquidCadence(reduceMotion: reduceMotion, windowState: activeState,
                                                       windowVisible: model.calendarVisible || AppDelegate.shared == nil,
                                                       compact: false))
                    ForEach(cells) { c in
                        let r = rect(c)
                        DayTile(cell: c,
                                seconds: totals[c.day] ?? 0,
                                pending: ledger.pendingSeconds(for: c.day),
                                goalSeconds: ledger.settings.dailyGoalSeconds,
                                isToday: c.day == today,
                                isFuture: c.day > today,
                                live: activeDays.contains(c.day),
                                focused: gridFocused && focusedDay == c.day,
                                size: r.size,
                                reduceMotion: reduceMotion,
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
        .focusable()
        .focused($gridFocused)
        .focusEffectDisabled()
        .onMoveCommand { direction in
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

/// Text, marks and interaction layered over the Canvas-drawn liquid for one day.
struct DayTile: View {
    var cell: MonthGridCell
    var seconds: TimeInterval
    var pending: TimeInterval
    var goalSeconds: TimeInterval
    var isToday: Bool
    var isFuture: Bool
    var live: Bool
    var focused: Bool
    var size: CGSize
    var reduceMotion: Bool
    var open: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let fraction = LiquidScale.fillFraction(seconds: seconds)
        let metGoal = goalSeconds > 0 && seconds >= goalSeconds
        let corner = min(16, size.width * 0.14)
        let compactText = size.height < 70

        Button(action: open) {
            Group {
                if cell.isInDisplayedMonth {
                    // Two-tone labels split at the waterline: always legible over liquid or tile.
                    WaterlineSplit(fraction: fraction, height: size.height, animate: !reduceMotion) { submerged in
                        labels(submerged: submerged, metGoal: metGoal, compactText: compactText)
                    }
                } else {
                    // Adjacent-month days: liquid is faded, so plain subdued labels read best.
                    labels(submerged: false, metGoal: metGoal, compactText: compactText)
                        .opacity(0.6)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .overlay {
            if isToday {
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
        .accessibilityLabel(accessibilityText(metGoal: metGoal))
        .accessibilityHint("Opens the session editor for this day")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { open() }
        .help("\(DateFormatter.make("EEEEdMMMMyyyy", calendar: model.calendar).string(from: cell.day.noon(in: model.calendar))) — \(DurationFormat.short(seconds))")
    }

    @ViewBuilder
    private func labels(submerged: Bool, metGoal: Bool, compactText: Bool) -> some View {
        let primary: Color = submerged ? Theme.onLiquid : .primary
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 4) {
                Text("\(cell.day.day)")
                    .font(.system(size: compactText ? 13 : 16, weight: isToday ? .heavy : .semibold, design: .rounded))
                    .foregroundStyle(submerged ? Theme.onLiquid : (isToday ? Theme.orangeDeep : .primary))
                    .padding(.horizontal, isToday ? 6 : 0)
                    .padding(.vertical, isToday ? 1 : 0)
                    .background {
                        if isToday {
                            Capsule().fill((submerged ? Color.white : Theme.orange).opacity(submerged ? 0.35 : 0.16))
                        }
                    }
                Spacer(minLength: 0)
                if live {
                    Circle().fill(submerged ? Theme.onLiquid : Theme.orange).frame(width: 7, height: 7)
                        .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 1))
                        .padding(.top, 4)
                }
                if metGoal {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: compactText ? 10 : 12))
                        .foregroundStyle(submerged ? Theme.onLiquid.opacity(0.8) : Theme.orange)
                        .accessibilityHidden(true)
                }
            }
            Spacer(minLength: 0)
            if pending > 0 {
                Label(DurationFormat.short(pending), systemImage: "questionmark.circle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(submerged ? Theme.onLiquid : .red)
                    .labelStyle(.titleAndIcon)
                    .help("Pending review — not counted yet")
            }
            HStack(alignment: .lastTextBaseline, spacing: 3) {
                Text(DurationFormat.short(seconds))
                    .font(.system(size: compactText ? 11.5 : 13.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .foregroundStyle(seconds > 0 || submerged ? primary : Theme.secondaryText(scheme).opacity(isFuture ? 0.6 : 1))
                if LiquidScale.isOverflowing(seconds: seconds) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(primary)
                        .accessibilityHidden(true)
                }
            }
        }
        .padding(.horizontal, compactText ? 7 : 10)
        .padding(.vertical, compactText ? 6 : 9)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func accessibilityText(metGoal: Bool) -> String {
        let date = DateFormatter.make("EEEEdMMMMyyyy", calendar: model.calendar).string(from: cell.day.noon(in: model.calendar))
        var parts = [date, DurationFormat.spoken(seconds) + (seconds > 0 ? " worked" : "")]
        if isToday { parts.insert("Today", at: 0) }
        if live { parts.append("timer running") }
        if metGoal { parts.append("goal met") }
        if LiquidScale.isOverflowing(seconds: seconds) { parts.append("more than 18 hours") }
        if pending > 0 { parts.append("\(DurationFormat.spoken(pending)) pending review") }
        return parts.joined(separator: ", ")
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

    /// The day-grid area inside a mini month panel of `size`, in panel coordinates.
    static func gridFrame(panel size: CGSize) -> CGRect {
        let top = padding + headerHeight + spacing + weekdayHeight + spacing
        return CGRect(x: padding, y: top, width: max(0, size.width - padding * 2), height: max(0, size.height - top - padding))
    }

    static func side(in size: CGSize) -> CGFloat {
        max(4, min((size.width - gap * 6) / 7, (size.height - gap * 5) / 6))
    }

    /// Rect of a cell relative to the grid area's origin.
    static func rect(_ c: MonthGridCell, in size: CGSize) -> CGRect {
        let side = side(in: size)
        let originX = (size.width - (side * 7 + gap * 6)) / 2
        return CGRect(x: originX + CGFloat(c.column) * (side + gap), y: CGFloat(c.row) * (side + gap), width: side, height: side)
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
        let readoutDay = (focused ? focusedDay : nil) ?? hovered

        VStack(alignment: .leading, spacing: 10) {
            // Hover/focus readout with exact hours for the tiny tiles.
            HStack(spacing: 6) {
                Image(systemName: focused ? "keyboard" : "hand.point.up.left").foregroundStyle(Theme.secondaryText(scheme))
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
                let columns = geo.size.width > 900 ? 4 : 3
                let rows = 12 / columns
                let gap: CGFloat = 18
                let w = (geo.size.width - gap * CGFloat(columns - 1)) / CGFloat(columns)
                let h = (geo.size.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
                let origin: (Int) -> CGPoint = { i in CGPoint(x: CGFloat(i % columns) * (w + gap), y: CGFloat(i / columns) * (h + gap)) }

                // One canvas and one timeline for all 365 tiles.
                let liquid: [LiquidCell] = months.enumerated().flatMap { i, m -> [LiquidCell] in
                    let frame = MiniMonthGeometry.gridFrame(panel: CGSize(width: w, height: h)).offsetBy(dx: origin(i).x, dy: origin(i).y)
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
                        MiniMonthView(month: m, totals: totals, today: today,
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
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onMoveCommand { direction in
            let current = focusedDay ?? (today.year == year ? today : DayKey(year: year, month: 1, day: 1))
            let next = current.adding(days: gridStep(direction), calendar: cal)
            if next.year == year { focusedDay = next }
        }
        .onKeyPress(.return) {
            if let day = focusedDay { onOpenDay(day) }
            return .handled
        }
        .onAppear {
            focusedDay = today.year == year ? today : DayKey(year: year, month: 1, day: 1)
        }
    }
}

struct MiniMonthView: View {
    var month: MonthKey
    var totals: [DayKey: TimeInterval]
    var today: DayKey
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
                let side = MiniMonthGeometry.side(in: geo.size)
                ZStack(alignment: .topLeading) {
                    ForEach(inMonth) { c in
                        let r = MiniMonthGeometry.rect(c, in: geo.size)
                        let seconds = totals[c.day] ?? 0
                        let isToday = c.day == today
                        Button { onOpenDay(c.day) } label: {
                            WaterlineSplit(fraction: LiquidScale.fillFraction(seconds: seconds), height: r.height, animate: false) { submerged in
                                Text("\(c.day.day)")
                                    .font(.system(size: max(7.5, min(11, side * 0.36)), weight: isToday ? .heavy : .semibold, design: .rounded))
                                    .foregroundStyle(submerged ? Theme.onLiquid : (isToday ? Theme.orangeDeep : Color.primary.opacity(0.8)))
                                    .frame(width: r.width, height: r.height)
                            }
                            .frame(width: r.width, height: r.height)
                            .overlay {
                                if isToday {
                                    RoundedRectangle(cornerRadius: side * 0.22, style: .continuous)
                                        .strokeBorder(Theme.orange, lineWidth: 1.5)
                                }
                            }
                            .overlay {
                                if focusedDay == c.day {
                                    RoundedRectangle(cornerRadius: side * 0.22 + 2, style: .continuous)
                                        .strokeBorder(Color.accentColor, lineWidth: 2)
                                        .padding(-2)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .focusable(false)
                        .offset(x: r.minX, y: r.minY)
                        .onHover { inside in
                            if inside {
                                hovered = c.day
                                onHoverDay(c.day)
                            } else if hovered == c.day { hovered = nil }
                        }
                        .help("\(DateFormatter.make("EEEdMMM", calendar: cal).string(from: c.day.noon(in: cal))) — \(DurationFormat.short(seconds))")
                        .accessibilityLabel("\(DateFormatter.make("EEEEdMMMMyyyy", calendar: cal).string(from: c.day.noon(in: cal))), \(DurationFormat.spoken(seconds))")
                        .accessibilityHint("Opens the session editor for this day")
                    }
                }
            }
        }
        .padding(MiniMonthGeometry.padding)
    }
}
