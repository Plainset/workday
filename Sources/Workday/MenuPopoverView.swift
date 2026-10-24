import SwiftUI
import WorkdayCore

/// The compact dropdown shown from the menu bar item.
struct MenuPopoverView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ledger = model.ledger
        let now = model.now
        let today = ledger.today(now: now)
        let total = ledger.total(for: today, now: now)
        let goal = ledger.settings.dailyGoalSeconds
        let running = ledger.isRunning
        let streak = ledger.streak(now: now)

        VStack(alignment: .leading, spacing: 14) {
            // Header: date + status.
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Today")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.secondaryText(scheme))
                        .textCase(.uppercase)
                    Text(DateFormatter.make("EEEEdMMMM", calendar: model.calendar).string(from: now))
                        .font(.system(size: 13, weight: .medium))
                }
                Spacer()
                StatusPill(running: running)
            }

            // Big total + live session.
            HStack(alignment: .center, spacing: 14) {
                MiniGlass(seconds: total, live: running, visible: model.popoverVisible || AppDelegate.shared == nil)
                    .frame(width: 46, height: 58)
                VStack(alignment: .leading, spacing: 3) {
                    Text(running ? DurationFormat.precise(total) : DurationFormat.short(total))
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .accessibilityLabel("Today \(DurationFormat.spoken(total))")
                    if let active = ledger.activeSession {
                        Text("Session \(DurationFormat.precise(ledger.activeElapsed(now: now))) · since \(DateFormatter.time(calendar: model.calendar).string(from: active.start))")
                            .font(.system(size: 12))
                            .monospacedDigit()
                            .foregroundStyle(Theme.secondaryText(scheme))
                    } else {
                        let touching = ledger.sessions(touching: today, now: now)
                        let count = touching.count
                        let review = touching.filter(\.isInterrupted).count
                        Text(count == 0 ? "No sessions yet today"
                             : "\(count) session\(count == 1 ? "" : "s") today" + (review > 0 ? " · \(review) needs review" : ""))
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondaryText(scheme))
                    }
                }
            }

            // Goal progress.
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(total >= goal ? "Goal reached" : "Goal \(DurationFormat.goal(minutes: ledger.settings.dailyGoalMinutes))")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text(total >= goal
                         ? "\(Int((total / max(goal, 1)) * 100))%"
                         : "\(DurationFormat.short(goal - total)) to go")
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(Theme.secondaryText(scheme))
                }
                ProgressLine(progress: goal > 0 ? total / goal : 0)
                if streak > 0 {
                    Label("\(streak)-day goal streak", systemImage: "flame.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.orangeDeep)
                }
            }
            .accessibilityElement(children: .combine)

            if ledger.hasPendingRecovery {
                RecoveryNotice()
            }
            BackupFailureNotice()

            // Primary action: explicit, labelled with its consequence.
            Button {
                running ? model.stop() : model.start()
            } label: {
                HStack {
                    Image(systemName: running ? "stop.fill" : "play.fill")
                    Text(running ? "Stop Work" : "Start Work")
                    Spacer()
                    Text(running ? "ends this session now" : "starts timing now")
                        .font(.system(size: 11, weight: .regular))
                        .opacity(0.75)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(PillButtonStyle(kind: running ? .secondary : .primary))
            .accessibilityHint(running ? "Stops the timer and records this session" : "Starts the work timer")

            if let message = model.errorMessage {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack(spacing: 8) {
                Button { AppDelegate.shared?.showCalendar() } label: { Label("Calendar", systemImage: "calendar") }
                    .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
                Button { AppDelegate.shared?.showSettings() } label: { Label("Settings", systemImage: "gearshape") }
                    .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
                Spacer()
                Button { NSApp.terminate(nil) } label: { Text("Quit") }
                    .buttonStyle(PillButtonStyle(kind: .plain, compact: true))
            }
        }
        .padding(16)
        .frame(width: 320)
        .background(Theme.panelBackground(scheme))
    }
}

struct StatusPill: View {
    var running: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(running ? Theme.orange : Theme.secondaryText(scheme).opacity(0.6))
                .frame(width: 7, height: 7)
            Text(running ? "Running" : "Stopped")
                .font(.system(size: 11, weight: .semibold))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(running ? Theme.orange.opacity(0.16) : Theme.subtleFill(scheme), in: Capsule())
        .accessibilityLabel(running ? "Status: running" : "Status: stopped")
    }
}

struct RecoveryNotice: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let pending = model.ledger.pendingRecoveries
        let gap = pending.compactMap(\.pendingGap).reduce(0) { $0 + $1.duration }
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 4) {
                Text("Interrupted session needs review")
                    .font(.system(size: 12, weight: .semibold))
                Text("\(DurationFormat.short(gap)) of uncertain time is not counted until you decide.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText(scheme))
                    .fixedSize(horizontal: false, vertical: true)
                Button("Review…") { AppDelegate.shared?.showRecovery() }
                    .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// A single animated liquid glass used in the popover and editor.
struct MiniGlass: View {
    var seconds: TimeInterval
    var live: Bool
    /// The hosting window/popover is on screen; otherwise a single still frame is drawn.
    var visible: Bool
    @State private var motion = LiquidMotion()
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.forceReducedMotion) private var forceReducedMotion
    private var reduceMotion: Bool { systemReduceMotion || forceReducedMotion }

    var body: some View {
        GeometryReader { geo in
            LiquidLayer(cells: [LiquidCell(key: DayKey(year: 2000, month: 1, day: 1),
                                           rect: CGRect(origin: .zero, size: geo.size).insetBy(dx: 2, dy: 2),
                                           cornerRadius: 10, seconds: seconds, dimmed: false, live: live)],
                        motion: motion,
                        cadence: LiquidCadence(reduceMotion: reduceMotion, windowState: activeState, windowVisible: visible, compact: false))
        }
        .accessibilityHidden(true)
    }
}

/// Non-modal warning shown when the most recent automatic backup failed.
struct BackupFailureNotice: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if case .failed(let message) = model.backupStatus {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "externaldrive.badge.exclamationmark").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Backup failed").font(.system(size: 12, weight: .semibold))
                    Text(message).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Backup Settings…") { AppDelegate.shared?.showSettings() }
                        .buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityElement(children: .combine)
        }
    }
}
