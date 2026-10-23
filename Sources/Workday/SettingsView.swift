import SwiftUI
import WorkdayCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            NotificationSettings().tabItem { Label("Notifications", systemImage: "bell") }
            BackupSettings().tabItem { Label("Backups", systemImage: "externaldrive") }
            PrivacySettings().tabItem { Label("Data & Privacy", systemImage: "lock") }
        }
        .padding(18)
        .frame(minWidth: 560, minHeight: 480)
        .task {
            model.launchAtLogin.refresh()
            await model.notifications.refresh()
            model.refreshBackupStatus()
        }
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let settings = model.ledger.settings
        let hours = Binding<Int>(
            get: { settings.dailyGoalMinutes / 60 },
            set: { h in model.perform { try model.ledger.updateSettings { $0.dailyGoalMinutes = h * 60 + settings.dailyGoalMinutes % 60 } } })
        let minutes = Binding<Int>(
            get: { settings.dailyGoalMinutes % 60 },
            set: { m in model.perform { try model.ledger.updateSettings { $0.dailyGoalMinutes = (settings.dailyGoalMinutes / 60) * 60 + m } } })

        Form {
            Section("Daily goal") {
                HStack {
                    Stepper(value: hours, in: 0...24) { Text("\(hours.wrappedValue) h") }
                        .accessibilityLabel("Goal hours")
                    Picker("Minutes", selection: minutes) {
                        ForEach(Array(stride(from: 0, to: 60, by: 5)), id: \.self) { Text("\($0) min").tag($0) }
                    }
                    .frame(width: 140)
                    Spacer()
                    Text("Goal: \(DurationFormat.goal(minutes: settings.dailyGoalMinutes))")
                        .font(.system(size: 13, weight: .semibold))
                }
                Text("One goal applies to every day, weekends included. The liquid scale is fixed — a tile is full at 18 hours regardless of the goal.")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("Streaks count consecutive days that meet the current goal. Today never breaks a streak while it's in progress; a completed day below the goal does. Changing the goal re-evaluates past days with the new goal.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Startup") {
                LaunchAtLoginRow()
                Text("Workday starts quietly in the menu bar at login — the calendar window doesn't open. Closing the calendar never stops the timer.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct LaunchAtLoginRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let login = model.launchAtLogin
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Open Workday at login", isOn: Binding(
                get: { login.state == .enabled || login.state == .requiresApproval },
                set: { login.setEnabled($0) }))
            .disabled({ if case .unavailable = login.state { return true } else { return false } }())
            switch login.state {
            case .requiresApproval:
                HStack {
                    Label("Needs your approval in System Settings → General → Login Items.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button("Open Login Items") { login.openLoginItemsSettings() }
                }
                .font(.footnote)
            case .unavailable(let why):
                Text(why).font(.footnote).foregroundStyle(.secondary)
            case .enabled:
                Label("Enabled", systemImage: "checkmark.circle.fill").font(.footnote).foregroundStyle(.green)
            case .disabled:
                EmptyView()
            }
            if let error = login.lastError {
                Text("Couldn't change the login item: \(error)").font(.footnote).foregroundStyle(.red)
            }
        }
    }
}

private struct NotificationSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let s = model.ledger.settings
        let cal = model.calendar
        Form {
            Section {
                PermissionRow()
            }
            Section("Goal") {
                Toggle("Notify me once when today's goal is reached", isOn: Binding(
                    get: { s.goalNotificationEnabled },
                    set: { on in setFeature(on) { $0.goalNotificationEnabled = on } }))
            }
            Section("Reminders") {
                Toggle("Remind me to start work", isOn: Binding(
                    get: { s.startReminderEnabled },
                    set: { on in setFeature(on) { $0.startReminderEnabled = on } }))
                DatePicker("Start reminder time", selection: minuteBinding(s.startReminderMinutes, cal: cal) { m in
                    model.perform { try model.ledger.updateSettings { $0.startReminderMinutes = m } }
                }, displayedComponents: .hourAndMinute)
                .disabled(!s.startReminderEnabled)
                Text("Sent once on days the timer isn't running at that time (up to 3 hours late if your Mac was asleep).")
                    .font(.footnote).foregroundStyle(.secondary)

                Toggle("Remind me if the timer is still running", isOn: Binding(
                    get: { s.stopReminderEnabled },
                    set: { on in setFeature(on) { $0.stopReminderEnabled = on } }))
                DatePicker("Check-in time", selection: minuteBinding(s.stopReminderMinutes, cal: cal) { m in
                    model.perform { try model.ledger.updateSettings { $0.stopReminderMinutes = m } }
                }, displayedComponents: .hourAndMinute)
                .disabled(!s.stopReminderEnabled)
                Text("Sent at most once a day. Workday works fully without notifications.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func setFeature(_ on: Bool, _ change: @escaping (inout WorkdaySettings) -> Void) {
        if on {
            model.enableNotificationFeature(change)
        } else {
            model.perform { try model.ledger.updateSettings(change) }
        }
    }

    private func minuteBinding(_ minutes: Int, cal: Calendar, set: @escaping (Int) -> Void) -> Binding<Date> {
        Binding(
            // Built from hour/minute components so DST days don't shift the displayed time.
            get: { cal.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date() },
            set: { set(TimeMath.minuteOfDay($0, calendar: cal)) })
    }
}

private struct PermissionRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let n = model.notifications
        HStack {
            switch n.permission {
            case .authorized:
                Label("Notifications are allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .notDetermined:
                Label("Workday asks for permission once when any notification below is on (the goal notice is on by default).", systemImage: "bell.badge")
            case .denied:
                Label("Notifications are turned off for Workday in System Settings. Reminders won't appear.", systemImage: "bell.slash.fill")
                    .foregroundStyle(.orange)
                Spacer()
                Button("Open Settings") { n.openSystemSettings() }
            case .unavailable:
                Label("Notifications require running the installed Workday.app.", systemImage: "bell.slash")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }
}

private struct BackupSettings: View {
    @Environment(AppModel.self) private var model
    @State private var backups: [BackupInfo] = []
    @State private var confirmRestore: BackupInfo?
    @State private var message: String?

    var body: some View {
        Form {
            Section("Status") {
                switch model.backupStatus {
                case .ok(let date):
                    Label("Last backup \(date.formatted(date: .abbreviated, time: .shortened))", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .none:
                    Label("No backups yet. One is made automatically each day your data changes.", systemImage: "clock")
                case .failed(let error):
                    Label("Last backup failed: \(error)", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                case .unknown:
                    Text("Checking…")
                }
                Text("Automatic snapshots are taken once per day when your data has changed. The newest 30 daily snapshots are kept, plus 20 manual backups and 10 safety copies made before each restore. Backups never leave this Mac.")
                    .font(.footnote).foregroundStyle(.secondary)
                HStack {
                    Button("Back Up Now") {
                        message = model.backupNow() ? "Backup created." : nil
                        reload()
                    }
                    Button("Show in Finder") {
                        try? FileManager.default.createDirectory(at: WorkdayPaths.backupsDirectory, withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([WorkdayPaths.backupsDirectory])
                    }
                    if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
                }
            }
            Section("Available backups") {
                if backups.isEmpty {
                    Text("No backups found.").foregroundStyle(.secondary)
                }
                ForEach(backups) { b in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(b.createdAt.formatted(date: .abbreviated, time: .shortened))
                            Text(b.isValid ? "\(b.kind.label) · \(b.sessionCount ?? 0) sessions · \(ByteCountFormatter.string(fromByteCount: b.sizeBytes, countStyle: .file))"
                                           : "\(b.kind.label) · Unusable: \(b.problem ?? "")")
                                .font(.footnote)
                                .foregroundStyle(b.isValid ? Color.secondary : Color.red)
                        }
                        Spacer()
                        Button("Restore…") { confirmRestore = b }
                            .disabled(!b.isValid || model.isRunning)
                            .help(model.isRunning ? "Stop the timer before restoring" : "Replace current data with this backup")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: reload)
        .alert("Restore this backup?", isPresented: Binding(get: { confirmRestore != nil }, set: { if !$0 { confirmRestore = nil } }),
               presenting: confirmRestore) { b in
            Button("Restore", role: .destructive) {
                message = model.restore(b) ? "Restored. Your previous data was saved as a safety copy." : model.errorMessage
                confirmRestore = nil
                reload()
            }
            Button("Cancel", role: .cancel) { confirmRestore = nil }
        } message: { b in
            Text("All sessions and settings will be replaced with the backup from \(b.createdAt.formatted(date: .abbreviated, time: .shortened)). A safety copy of your current data is saved first, so this can be reversed.")
        }
    }

    private func reload() {
        backups = model.backups.list()
        model.refreshBackupStatus()
    }
}

private struct PrivacySettings: View {
    var body: some View {
        Form {
            Section("Where your data lives") {
                Text("All work history, settings and backups are stored only on this Mac, in your user Library under Application Support → Workday. There are no accounts, no cloud sync, no analytics and no network access.")
                Button("Show Data Folder in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([WorkdayPaths.databaseURL])
                }
            }
            Section("How time is counted") {
                Text("Only the Start/Stop timer records work. While the timer runs, all wall-clock time counts — including idle time, screen lock and sleep.")
                Text("Sessions are stored as exact start and end instants. Daily totals are derived by splitting sessions at local midnight in your Mac's current time zone; durations are always real elapsed time, so DST changes never add or lose work.")
                Text("If Workday quits unexpectedly or your Mac shuts down while timing, the time up to the last confirmed moment is kept and you decide how to count the gap.")
            }
            .font(.callout)
        }
        .formStyle(.grouped)
    }
}
