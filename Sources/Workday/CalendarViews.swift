import SwiftUI
import WorkdayCore

enum CalendarMode: Hashable { case month, year }

/// The main calendar window: month-first with an optional twelve-month overview.
struct CalendarRootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
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
            if let error = model.errorMessage {
                ErrorBanner(message: error) { model.errorMessage = nil }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 10)
            }
            if model.ledger.hasPendingRecovery {
                RecoveryNotice()
                    .padding(.horizontal, 28)
                    .padding(.bottom, 10)
            }
            Group {
                switch mode {
                case .month:
                    MonthGridView(month: month, onOpen: { editingDay = $0 })
                        .id(month)
                        .transition(.asymmetric(insertion: .move(edge: direction >= 0 ? .trailing : .leading).combined(with: .opacity),
                                                removal: .opacity))
                case .year:
                    YearOverviewView(year: month.year,
                                     onOpenDay: { editingDay = $0 },
                                     onOpenMonth: { m in
                                         withAnimation(.snappy(duration: 0.35)) { month = m; mode = .month }
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
                .contentTransition(.numericText())
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
        withAnimation(.snappy(duration: 0.35)) {
            month = mode == .month ? month.adding(months: step) : month.adding(months: 12 * step)
        }
    }

    private func goToday() {
        let target = MonthKey(model.today)
        direction = target < month ? -1 : 1
        withAnimation(.snappy(duration: 0.35)) { month = target }
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

/// Minimal summary: month (or year) total, goal days, streak and today's goal progress.
struct SummaryStrip: View {
    var month: MonthKey
    var mode: CalendarMode
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ledger = model.ledger
        let now = model.now
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
        let todayTotal = model.todayTotal

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
                ProgressLine(progress: model.goalProgress, height: 5)
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
        let now = model.now
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
                let liquidCells = cells.map { c in
                    LiquidCell(key: c.day, rect: rect(c).insetBy(dx: hovered == c.day ? -2 : 0, dy: hovered == c.day ? -2 : 0),
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
                                open: { onOpen(c.day) })
                            .frame(width: r.width, height: r.height)
                            .offset(x: r.minX, y: r.minY)
                            .onHover { inside in
                                if inside {
                                    hovered = c.day
                                    motion.slosh(c.day, t: Date().timeIntervalSinceReferenceDate)
                                } else if hovered == c.day {
                                    hovered = nil
                                }
                            }
                    }
                }
                .animation(.easeOut(duration: 0.15), value: hovered)
            }
        }
        .focusable()
        .focused($gridFocused)
        .focusEffectDisabled()
        .onMoveCommand { direction in
            let current = focusedDay ?? (MonthKey(today) == month ? today : month.firstDay)
            let step: Int
            switch direction {
            case .left: step = -1
            case .right: step = 1
            case .up: step = -7
            case .down: step = 7
            @unknown default: step = 0
            }
            let next = current.adding(days: step, calendar: cal)
            if cells.contains(where: { $0.day == next && $0.isInDisplayedMonth }) {
                focusedDay = next
                motion.slosh(next, t: Date().timeIntervalSinceReferenceDate)
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
    var open: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let fraction = LiquidScale.fillFraction(seconds: seconds)
        let numberCovered = fraction > 0.72
        let durationCovered = fraction > 0.2
        let metGoal = goalSeconds > 0 && seconds >= goalSeconds
        let corner = min(16, size.width * 0.14)
        let compactText = size.height < 70

        Button(action: open) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 4) {
                    Text("\(cell.day.day)")
                        .font(.system(size: compactText ? 13 : 16, weight: isToday ? .heavy : .semibold, design: .rounded))
                        .foregroundStyle(numberCovered ? Theme.onLiquid : (isToday ? Theme.orangeDeep : .primary))
                        .padding(.horizontal, isToday ? 6 : 0)
                        .padding(.vertical, isToday ? 1 : 0)
                        .background {
                            if isToday && !numberCovered {
                                Capsule().fill(Theme.orange.opacity(0.16))
                            }
                        }
                    Spacer(minLength: 0)
                    if live {
                        Circle().fill(Theme.orange).frame(width: 7, height: 7)
                            .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 1))
                            .padding(.top, 4)
                    }
                    if metGoal {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: compactText ? 10 : 12))
                            .foregroundStyle(numberCovered ? Theme.onLiquid.opacity(0.75) : Theme.orange)
                            .accessibilityHidden(true)
                    }
                }
                Spacer(minLength: 0)
                if pending > 0 {
                    Label(DurationFormat.short(pending), systemImage: "questionmark.circle.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(durationCovered ? Theme.onLiquid : .red)
                        .labelStyle(.titleAndIcon)
                        .help("Pending review — not counted yet")
                }
                HStack(alignment: .lastTextBaseline, spacing: 3) {
                    Text(DurationFormat.short(seconds))
                        .font(.system(size: compactText ? 11.5 : 13.5, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                        .foregroundStyle(durationCovered ? Theme.onLiquid : (seconds > 0 ? Color.primary : Theme.secondaryText(scheme).opacity(isFuture ? 0.5 : 0.9)))
                    if LiquidScale.isOverflowing(seconds: seconds) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Theme.onLiquid)
                            .accessibilityHidden(true)
                    }
                }
            }
            .padding(.horizontal, compactText ? 7 : 10)
            .padding(.vertical, compactText ? 6 : 9)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .contentShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .opacity(cell.isInDisplayedMonth ? 1 : 0.45)
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

struct YearOverviewView: View {
    var year: Int
    var onOpenDay: (DayKey) -> Void
    var onOpenMonth: (MonthKey) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @State private var hovered: DayKey?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Hover/focus readout with exact hours for the tiny tiles.
            HStack(spacing: 6) {
                Image(systemName: "hand.point.up.left").foregroundStyle(Theme.secondaryText(scheme))
                if let hovered {
                    Text(DateFormatter.make("EEEEdMMMMyyyy", calendar: model.calendar).string(from: hovered.noon(in: model.calendar)))
                        .font(.system(size: 12, weight: .semibold))
                    Text(DurationFormat.short(model.ledger.total(for: hovered, now: model.now)))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Theme.orangeDeep)
                } else {
                    Text("Hover over a day to see its exact hours · click to edit · click a month name to open it")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText(scheme))
                }
            }
            .frame(height: 18)
            .padding(.horizontal, 6)

            GeometryReader { geo in
                let columns = geo.size.width > 900 ? 4 : 3
                let rows = 12 / columns
                let gap: CGFloat = 18
                let w = (geo.size.width - gap * CGFloat(columns - 1)) / CGFloat(columns)
                let h = (geo.size.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
                ZStack(alignment: .topLeading) {
                    ForEach(1...12, id: \.self) { m in
                        let i = m - 1
                        MiniMonthView(month: MonthKey(year: year, month: m), hovered: $hovered,
                                      onOpenDay: onOpenDay, onOpenMonth: onOpenMonth)
                            .frame(width: w, height: h)
                            .offset(x: CGFloat(i % columns) * (w + gap), y: CGFloat(i / columns) * (h + gap))
                    }
                }
            }
        }
    }
}

struct MiniMonthView: View {
    var month: MonthKey
    @Binding var hovered: DayKey?
    var onOpenDay: (DayKey) -> Void
    var onOpenMonth: (MonthKey) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.forceReducedMotion) private var forceReducedMotion
    private var reduceMotion: Bool { systemReduceMotion || forceReducedMotion }
    @Environment(\.controlActiveState) private var activeState
    @State private var motion = LiquidMotion()

    var body: some View {
        let cal = model.calendar
        let cells = MonthGridLayout.cells(for: month, calendar: cal, fixedSixRows: true)
        let ledger = model.ledger
        let now = model.now
        let today = model.today
        let totals = ledger.totals(for: cells.filter(\.isInDisplayedMonth).map(\.day), now: now)
        let monthTotal = totals.values.reduce(0, +)
        let name = DateFormatter.make("MMMM", calendar: cal).string(from: month.firstDay.noon(in: cal))

        VStack(alignment: .leading, spacing: 5) {
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
            .accessibilityLabel("\(name) \(month.year), \(DurationFormat.spoken(monthTotal)). Opens month view.")

            HStack(spacing: 3) {
                ForEach(Array(MonthGridLayout.weekdaySymbols(calendar: cal, veryShort: true).enumerated()), id: \.offset) { _, s in
                    Text(s).font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(Theme.secondaryText(scheme))
                        .frame(maxWidth: .infinity)
                }
            }
            .accessibilityHidden(true)

            GeometryReader { geo in
                let gap: CGFloat = 3
                let side = min((geo.size.width - gap * 6) / 7, (geo.size.height - gap * 5) / 6)
                let originX = (geo.size.width - (side * 7 + gap * 6)) / 2
                let rect: (MonthGridCell) -> CGRect = { c in
                    CGRect(x: originX + CGFloat(c.column) * (side + gap), y: CGFloat(c.row) * (side + gap), width: side, height: side)
                }
                let inMonth = cells.filter(\.isInDisplayedMonth)
                ZStack(alignment: .topLeading) {
                    LiquidLayer(cells: inMonth.map { c in
                                    LiquidCell(key: c.day, rect: rect(c), cornerRadius: side * 0.22,
                                               seconds: totals[c.day] ?? 0, dimmed: false, live: false, compact: true)
                                },
                                motion: motion,
                                cadence: LiquidCadence(reduceMotion: reduceMotion, windowState: activeState,
                                                       windowVisible: model.calendarVisible || AppDelegate.shared == nil,
                                                       compact: true))
                    ForEach(inMonth) { c in
                        let r = rect(c)
                        let seconds = totals[c.day] ?? 0
                        let covered = LiquidScale.fillFraction(seconds: seconds) > 0.45
                        Button { onOpenDay(c.day) } label: {
                            Text("\(c.day.day)")
                                .font(.system(size: max(7.5, min(11, side * 0.36)), weight: c.day == today ? .heavy : .medium, design: .rounded))
                                .foregroundStyle(covered ? Theme.onLiquid : (c.day == today ? Theme.orangeDeep : .primary.opacity(0.75)))
                                .frame(width: r.width, height: r.height)
                                .overlay {
                                    if c.day == today {
                                        RoundedRectangle(cornerRadius: side * 0.22, style: .continuous)
                                            .strokeBorder(Theme.orange, lineWidth: 1.5)
                                    }
                                }
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .offset(x: r.minX, y: r.minY)
                        .onHover { inside in
                            if inside {
                                hovered = c.day
                                motion.slosh(c.day, t: Date().timeIntervalSinceReferenceDate)
                            } else if hovered == c.day { hovered = nil }
                        }
                        .help("\(DateFormatter.make("EEEdMMM", calendar: cal).string(from: c.day.noon(in: cal))) — \(DurationFormat.short(seconds))")
                        .accessibilityLabel("\(DateFormatter.make("EEEEdMMMMyyyy", calendar: cal).string(from: c.day.noon(in: cal))), \(DurationFormat.spoken(seconds))")
                        .accessibilityHint("Opens the session editor for this day")
                    }
                }
            }
        }
        .padding(12)
        .background(Theme.panelBackground(scheme).opacity(scheme == .dark ? 0.6 : 0.85),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.tileBorder(scheme)))
    }
}
