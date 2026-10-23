import SwiftUI
import WorkdayCore

/// Sheet listing every session portion that affects a date, with add/edit/delete.
struct DayEditorView: View {
    let day: DayKey
    var close: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme

    enum Draft: Equatable {
        case new
        case existing(UUID)
    }

    @State private var draft: Draft?
    @State private var draftStart = Date()
    @State private var draftEnd = Date()
    @State private var pendingDelete: WorkSession?

    var body: some View {
        let ledger = model.ledger
        let cal = model.calendar
        let now = model.now
        let total = ledger.total(for: day, now: now)
        let pending = ledger.pendingSeconds(for: day)
        let sessions = ledger.sessions(touching: day, now: now)
        let goal = ledger.settings.dailyGoalSeconds

        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack(alignment: .top, spacing: 16) {
                MiniGlass(seconds: total, live: ledger.activeSession.map { sessions.contains($0) } ?? false)
                    .frame(width: 54, height: 70)
                VStack(alignment: .leading, spacing: 4) {
                    Text(DateFormatter.make("EEEEdMMMMyyyy", calendar: cal).string(from: day.noon(in: cal)))
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .accessibilityAddTraits(.isHeader)
                    HStack(spacing: 8) {
                        Text(DurationFormat.short(total))
                            .font(.system(size: 26, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        if total >= goal && goal > 0 {
                            Label("Goal met", systemImage: "checkmark.seal.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.orangeDeep)
                        } else {
                            Text("of \(DurationFormat.goal(minutes: ledger.settings.dailyGoalMinutes)) goal")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.secondaryText(scheme))
                        }
                        if LiquidScale.isOverflowing(seconds: total) {
                            Label("Beyond 18h", systemImage: "sparkles")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.orangeDeep)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                Spacer()
            }

            if pending > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "questionmark.circle.fill").foregroundStyle(.red)
                    Text("\(DurationFormat.short(pending)) on this day is pending review and is not counted until you decide.")
                        .font(.system(size: 12))
                    Spacer()
                    Button("Review…") { AppDelegate.shared?.showRecovery() }
                        .buttonStyle(PillButtonStyle(compact: true))
                }
                .padding(10)
                .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }

            // Session list
            VStack(alignment: .leading, spacing: 0) {
                if sessions.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "drop")
                            .font(.system(size: 22))
                            .foregroundStyle(Theme.orange.opacity(0.7))
                        Text("No work recorded on this day.")
                            .font(.system(size: 13, weight: .medium))
                        Text("Add a session if you forgot to start the timer.")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondaryText(scheme))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 22)
                } else {
                    ForEach(sessions) { s in
                        if draft == .existing(s.id) {
                            sessionForm(existing: s)
                        } else {
                            SessionRow(session: s, day: day,
                                       onEdit: { beginEdit(s) },
                                       onDelete: { pendingDelete = s })
                        }
                        if s.id != sessions.last?.id { Divider() }
                    }
                }
            }
            .padding(.horizontal, 12)
            .background(Theme.subtleFill(scheme).opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            if draft == .new {
                sessionForm(existing: nil)
                    .padding(.horizontal, 12)
                    .background(Theme.subtleFill(scheme).opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            if let error = model.errorMessage {
                Text(error).font(.system(size: 12)).foregroundStyle(.red)
            }

            HStack {
                if draft == nil {
                    Button { beginAdd() } label: { Label("Add Session", systemImage: "plus") }
                        .buttonStyle(PillButtonStyle(compact: true))
                        .disabled(day > model.today)
                        .help(day > model.today ? "Future dates can't have recorded work yet" : "Add a past session to this day")
                }
                Spacer()
                Button("Done", action: close)
                    .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(22)
        .frame(width: 560)
        .frame(minHeight: 320)
        .background(Theme.panelBackground(scheme))
        .confirmationDialog("Delete this session?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            presenting: pendingDelete) { s in
            Button("Delete Session", role: .destructive) {
                model.perform { try model.ledger.deleteSession(id: s.id) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { s in
            Text(deleteMessage(s))
        }
        .onAppear { model.errorMessage = nil }
    }

    private func deleteMessage(_ s: WorkSession) -> String {
        let span = TimeMath.slices(start: s.start, end: s.confirmedEnd(now: model.now), calendar: model.calendar)
        var text = "This removes \(DurationFormat.short(s.confirmedDuration(now: model.now))) of recorded work"
        if span.count > 1 { text += " across \(span.count) days" }
        if s.isActive { text += " and discards the running timer" }
        if s.isInterrupted { text += ", including the confirmed part of this interrupted session" }
        return text + ". This can't be undone (backups are kept in Settings → Backups)."
    }

    private func beginAdd() {
        let cal = model.calendar
        let start = day.startDate(in: cal).addingTimeInterval(9 * 3600)
        var end = day.startDate(in: cal).addingTimeInterval(17 * 3600)
        if day == model.today {
            end = min(end, model.now)
        }
        draftStart = min(start, end.addingTimeInterval(-3600))
        draftEnd = end
        model.errorMessage = nil
        draft = .new
    }

    private func beginEdit(_ s: WorkSession) {
        draftStart = s.start
        draftEnd = s.end ?? model.now
        model.errorMessage = nil
        draft = .existing(s.id)
    }

    @ViewBuilder
    private func sessionForm(existing: WorkSession?) -> some View {
        let ledger = model.ledger
        let cal = model.calendar
        let validationError: String? = {
            do {
                try ledger.validate(start: draftStart, end: draftEnd, excluding: existing?.id)
                return nil
            } catch {
                return (error as? LocalizedError)?.errorDescription
            }
        }()
        let impact = ledger.impact(old: existing.map { ($0.start, $0.end ?? model.now) },
                                   new: draftEnd > draftStart ? (draftStart, draftEnd) : nil)
        let otherDays = impact.filter { $0.day != day && abs($0.after - $0.before) >= 1 }

        VStack(alignment: .leading, spacing: 10) {
            Text(existing == nil ? "New session" : "Edit session")
                .font(.system(size: 13, weight: .semibold))
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Start").foregroundStyle(Theme.secondaryText(scheme))
                    DatePicker("Start", selection: $draftStart, displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                        .datePickerStyle(.stepperField)
                        .environment(\.timeZone, cal.timeZone)
                }
                GridRow {
                    Text("End").foregroundStyle(Theme.secondaryText(scheme))
                    DatePicker("End", selection: $draftEnd, displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                        .datePickerStyle(.stepperField)
                        .environment(\.timeZone, cal.timeZone)
                }
                GridRow {
                    Text("Duration").foregroundStyle(Theme.secondaryText(scheme))
                    Text(draftEnd > draftStart ? DurationFormat.short(draftEnd.timeIntervalSince(draftStart)) : "—")
                        .monospacedDigit()
                        .font(.system(size: 13, weight: .semibold))
                }
            }
            .font(.system(size: 12))

            if let validationError {
                Label(validationError, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !otherDays.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Label("This change also affects other days:", systemImage: "calendar.badge.exclamationmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.orangeDeep)
                    ForEach(otherDays, id: \.day) { row in
                        Text("\(DateFormatter.make("EEEdMMM", calendar: cal).string(from: row.day.noon(in: cal))): \(DurationFormat.short(row.before)) → \(DurationFormat.short(row.after))")
                            .font(.system(size: 12))
                            .monospacedDigit()
                    }
                }
            }
            if draftEnd.timeIntervalSince(draftStart) > LiquidScale.fullSeconds && validationError == nil {
                Text("This session is longer than 18 hours. Double-check the dates.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.orangeDeep)
            }

            HStack {
                Spacer()
                Button("Cancel") { draft = nil; model.errorMessage = nil }
                    .buttonStyle(PillButtonStyle(compact: true))
                Button("Save") {
                    let ok = model.perform {
                        if let existing {
                            try model.ledger.updateSession(id: existing.id, start: draftStart, end: draftEnd)
                        } else {
                            try model.ledger.addSession(start: draftStart, end: draftEnd)
                        }
                    }
                    if ok { draft = nil }
                }
                .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
                .disabled(validationError != nil)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.vertical, 12)
    }
}

struct SessionRow: View {
    let session: WorkSession
    let day: DayKey
    var onEdit: () -> Void
    var onDelete: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let cal = model.calendar
        let now = model.now
        let end = session.state == .interrupted ? (session.detectedAt ?? session.checkpoint) : session.confirmedEnd(now: now)
        let crosses = !cal.isDate(session.start, inSameDayAs: end)
        let timeF = DateFormatter.time(calendar: cal)
        let dateF = DateFormatter.make("EEEdMMM", calendar: cal)
        let portion = model.ledger.portion(of: session, on: day, now: now)
        let full = session.confirmedDuration(now: now)

        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if crosses {
                        Text("\(dateF.string(from: session.start)) \(timeF.string(from: session.start)) → \(session.isActive ? "now" : "\(dateF.string(from: end)) \(timeF.string(from: end))")")
                    } else {
                        Text("\(timeF.string(from: session.start)) → \(session.isActive ? "now" : timeF.string(from: end))")
                    }
                    switch session.state {
                    case .active:
                        badge("Running", color: Theme.orange)
                    case .interrupted:
                        badge("Needs review", color: .red)
                    case .closed:
                        EmptyView()
                    }
                }
                .font(.system(size: 13, weight: .medium))
                .monospacedDigit()
                Group {
                    if crosses {
                        Text("\(DurationFormat.short(portion)) on this day · \(DurationFormat.short(full)) in total")
                    } else if session.isInterrupted {
                        Text("\(DurationFormat.short(full)) confirmed · rest pending your decision")
                    } else {
                        Text(DurationFormat.short(portion))
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText(scheme))
            }
            .accessibilityElement(children: .combine)
            Spacer()
            switch session.state {
            case .active:
                Button("Stop Timer") { model.stop() }
                    .buttonStyle(PillButtonStyle(compact: true))
                    .help("Running sessions can be edited after you stop the timer")
            case .interrupted:
                Button("Review…") { AppDelegate.shared?.showRecovery() }
                    .buttonStyle(PillButtonStyle(compact: true))
            case .closed:
                Button("Edit", action: onEdit)
                    .buttonStyle(PillButtonStyle(compact: true))
            }
            Button(action: onDelete) { Image(systemName: "trash") }
                .buttonStyle(PillButtonStyle(kind: .destructive, compact: true))
                .accessibilityLabel("Delete session")
        }
        .padding(.vertical, 10)
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color)
    }
}
