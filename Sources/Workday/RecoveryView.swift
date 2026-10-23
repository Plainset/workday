import SwiftUI
import WorkdayCore

/// Non-destructive decision panel for sessions interrupted by a crash, force quit, power loss or reboot.
struct RecoveryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme

    enum Choice: Hashable { case count, exclude, custom }

    @State private var choice: Choice = .exclude
    @State private var customEnd = Date()
    @State private var useResume = false
    @State private var customResume = Date()
    @State private var keepRunning = false
    @State private var resumeFromRelaunch = false
    @State private var initializedFor: UUID?

    var body: some View {
        let pending = model.ledger.pendingRecoveries
        Group {
            if let session = pending.first {
                content(session, remaining: pending.count - 1)
                    .onAppear { initialize(session) }
                    .onChange(of: session.id) { _, _ in initialize(session) }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 34)).foregroundStyle(Theme.orange)
                    Text("Nothing to review").font(.system(size: 15, weight: .semibold))
                    Text("All sessions are settled.").foregroundStyle(Theme.secondaryText(scheme))
                    Button("Close") { AppDelegate.shared?.closeRecovery() }
                        .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(24)
        .background(Theme.panelBackground(scheme))
    }

    private func initialize(_ s: WorkSession) {
        guard initializedFor != s.id else { return }
        initializedFor = s.id
        customEnd = s.checkpoint
        customResume = s.detectedAt ?? s.checkpoint
        choice = .exclude
        keepRunning = false
        resumeFromRelaunch = false
    }

    @ViewBuilder
    private func content(_ s: WorkSession, remaining: Int) -> some View {
        let cal = model.calendar
        let full = DateFormatter.make("EEEdMMMjmm", calendar: cal)
        let detected = s.detectedAt ?? s.checkpoint
        let gap = s.pendingGap?.duration ?? 0
        let decision: RecoveryDecision = {
            switch choice {
            case .count: return .countGap
            case .exclude: return .excludeGap
            case .custom: return .custom(end: customEnd, resumedAt: useResume ? customResume : nil)
            }
        }()
        let canContinue = !model.ledger.isRunning
        // Deciding long after the relaunch: counting from the relaunch would add all the time since,
        // so the default is to start again from now and the alternative states the exact cost.
        let sinceRelaunch = max(0, model.now.timeIntervalSince(detected))
        let late = sinceRelaunch > 5 * 60
        let continuation: RecoveryContinuation = !(keepRunning && canContinue) ? .none
            : (!late || resumeFromRelaunch ? .fromRelaunch : .fromNow)
        let outcome = Result { try model.ledger.recoveryOutcome(for: s, decision: decision, continuation: continuation) }

        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                    .font(.system(size: 26))
                    .foregroundStyle(Theme.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Workday was interrupted while timing")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                    Text(s.checkpointKind.isExactStop
                         ? "Your Mac shut down, restarted or logged out while the timer was running."
                         : "Workday stopped unexpectedly (crash, force quit, power loss or restart) while the timer was running.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
                row("Session started", full.string(from: s.start))
                row("Last reliably observed", "\(full.string(from: s.checkpoint)) — \(s.checkpointKind.explanation)")
                row("Workday relaunched", full.string(from: detected))
                row("Confirmed so far", DurationFormat.short(s.confirmedDuration(now: model.now)), bold: true)
                row("Uncertain gap", DurationFormat.short(gap) + (s.checkpointKind.isExactStop ? " (Mac was off)" : " (exact stop time unknown)"), bold: true)
            }
            .font(.system(size: 12.5))
            .padding(12)
            .background(Theme.subtleFill(scheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 8) {
                Text("How should the gap be counted?").font(.system(size: 13, weight: .semibold))
                Picker("Gap", selection: $choice) {
                    Text("Exclude the gap — count only the confirmed \(DurationFormat.short(s.confirmedDuration(now: model.now)))").tag(Choice.exclude)
                    Text("Count the gap — I was working the whole time (+\(DurationFormat.short(gap)))").tag(Choice.count)
                    Text("Set the exact time I stopped").tag(Choice.custom)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()

                if choice == .custom {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("I stopped at").frame(width: 120, alignment: .leading)
                            DatePicker("Stopped at", selection: $customEnd, in: s.start...detected, displayedComponents: [.date, .hourAndMinute])
                                .labelsHidden().datePickerStyle(.stepperField)
                        }
                        Toggle("I resumed working before the relaunch", isOn: $useResume)
                        if useResume {
                            HStack {
                                Text("Resumed at").frame(width: 120, alignment: .leading)
                                DatePicker("Resumed at", selection: $customResume, in: s.start...detected, displayedComponents: [.date, .hourAndMinute])
                                    .labelsHidden().datePickerStyle(.stepperField)
                            }
                            Text("Counts \(DateFormatter.time(calendar: cal).string(from: customResume)) until the relaunch at \(DateFormatter.time(calendar: cal).string(from: detected)).")
                                .font(.system(size: 11)).foregroundStyle(Theme.secondaryText(scheme))
                        }
                    }
                    .font(.system(size: 12))
                    .padding(.leading, 20)
                }

                Toggle(isOn: $keepRunning) {
                    Text(late ? "Keep the timer running after applying"
                              : "Keep the timer running from the relaunch (\(DateFormatter.time(calendar: cal).string(from: detected))) onwards")
                }
                .disabled(!canContinue)
                .help(canContinue ? "" : "The timer is already running in a new session.")
                .font(.system(size: 12))
                if keepRunning && canContinue && late {
                    Picker("Resume", selection: $resumeFromRelaunch) {
                        Text("Start timing again now").tag(false)
                        Text("Count from the relaunch at \(full.string(from: detected)) (adds \(DurationFormat.short(sinceRelaunch)))").tag(true)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    .font(.system(size: 12))
                    .padding(.leading, 20)
                }
            }

            switch outcome {
            case .success(let o):
                VStack(alignment: .leading, spacing: 3) {
                    Text("Result").font(.system(size: 12, weight: .semibold))
                    if o.pieces.isEmpty {
                        Text("No time will be recorded for this session.").font(.system(size: 12))
                    }
                    ForEach(Array(o.pieces.enumerated()), id: \.offset) { _, p in
                        Text(p.end.map { "\(full.string(from: p.start)) → \(full.string(from: $0))  (\(DurationFormat.short($0.timeIntervalSince(p.start))))" }
                             ?? "\(full.string(from: p.start)) → running")
                            .font(.system(size: 12))
                            .monospacedDigit()
                    }
                }
            case .failure(let error):
                Label((error as? LocalizedError)?.errorDescription ?? "\(error)", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12)).foregroundStyle(.red)
            }

            if let error = model.errorMessage {
                Text(error).font(.system(size: 12)).foregroundStyle(.red)
            }

            Spacer(minLength: 0)
            HStack {
                if remaining > 0 {
                    Text("\(remaining) more to review").font(.system(size: 11)).foregroundStyle(Theme.secondaryText(scheme))
                }
                Spacer()
                Button("Decide Later") { AppDelegate.shared?.closeRecovery() }
                    .buttonStyle(PillButtonStyle(compact: true))
                    .keyboardShortcut(.cancelAction)
                Button("Apply") {
                    let ok = model.perform {
                        try model.ledger.resolveRecovery(sessionID: s.id, decision: decision, continuation: continuation)
                    }
                    AppDelegate.shared?.timerStateChanged()
                    if ok && !model.ledger.hasPendingRecovery { AppDelegate.shared?.closeRecovery() }
                }
                .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
                .disabled((try? outcome.get()) == nil)
            }
        }
    }

    private func row(_ label: String, _ value: String, bold: Bool = false) -> some View {
        GridRow {
            Text(label).foregroundStyle(Theme.secondaryText(scheme))
            Text(value).fontWeight(bold ? .semibold : .regular).monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
