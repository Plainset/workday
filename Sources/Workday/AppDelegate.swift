import AppKit
import SwiftUI
import WorkdayCore

/// Owns the application lifecycle: menu bar item, windows, Dock policy, timers and OS signals.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    static weak var shared: AppDelegate?

    private(set) var model: AppModel!
    private var instanceLock: SingleInstanceLock?
    private var statusItem: StatusItemController!
    private var calendarWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var recoveryWindow: NSWindow?

    private var displayTimer: Timer?
    private var heartbeatTimer: Timer?
    private var maintenanceTimer: Timer?
    private var napActivity: NSObjectProtocol?
    private var poweringOff = false

    static let showCalendarNotification = Notification.Name("io.github.plainset.workday.showCalendar")

    /// Identifies the data directory in the "show calendar" hand-off without broadcasting its path
    /// (which contains the account name) to other processes.
    static var instanceToken: String {
        WorkdayPaths.dataDirectory.path.utf8.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1)) &* 1099511628211 }
            .description
    }

    /// Checkpoint cadence while running; bounds the uncertainty of a crash.
    static let heartbeatInterval: TimeInterval = 30

    // MARK: Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        NSApp.setActivationPolicy(.accessory)

        guard let lock = SingleInstanceLock(url: WorkdayPaths.lockURL) else {
            // Another Workday is already running on this data: hand over and exit.
            // Ask the running instance to show its calendar so the user sees a response.
            DistributedNotificationCenter.default().postNotificationName(Self.showCalendarNotification, object: Self.instanceToken,
                                                                        userInfo: nil, deliverImmediately: true)
            NSApp.terminate(nil)
            return
        }
        instanceLock = lock

        let ledger: WorkLedger
        let store: WorkStore
        do {
            try OwnerOnly.createDirectory(at: WorkdayPaths.dataDirectory)
            store = try WorkStore(path: WorkdayPaths.databaseURL.path)
            ledger = try WorkLedger(store: store)
            // Any session still marked active belongs to a previous process that did not stop it.
            try ledger.detectInterruptions()
        } catch {
            fatalStartupError(error)
            return
        }
        if CommandLine.arguments.contains("--seed-demo") && WorkdayPaths.usesCustomDataDirectory && ledger.sessions.isEmpty {
            try? DemoData.seed(into: store, endingAt: ledger.today(), calendar: ledger.calendar)
            try? ledger.reload()
        }

        let backups = BackupManager(store: store, directory: WorkdayPaths.backupsDirectory)
        backups.tightenPermissions()
        model = AppModel(ledger: ledger, backups: backups, notifications: NotificationService(), launchAtLogin: LaunchAtLogin())
        statusItem = StatusItemController(model: model)
        buildMainMenu()
        observeSystem()
        startTimers()
        timerStateChanged()

        if CommandLine.arguments.contains("--perf") && WorkdayPaths.usesCustomDataDirectory {
            SnapshotRenderer.perf(model: model)
            return
        }
        model.launchAtLogin.refresh()
        firstLaunchSetup()
        Task {
            // The goal notification is on by default, so a fresh install asks for permission once here.
            await model.requestNotificationPermissionIfNeeded()
            model.evaluateReminders()
        }
        model.runAutomaticBackup()

        if ledger.hasPendingRecovery {
            // Recovery is shown without forcing the calendar open.
            showRecovery()
        } else if CommandLine.arguments.contains("--show-calendar") {
            showCalendar()
        }
    }

    private func firstLaunchSetup() {
        let settings = model.ledger.settings
        // Test/demo instances (custom data dir) never register a login item.
        if !settings.launchAtLoginInitialized && model.launchAtLogin.isBundled && !WorkdayPaths.usesCustomDataDirectory {
            model.launchAtLogin.setEnabled(true)
            model.perform { try model.ledger.updateSettings { $0.launchAtLoginInitialized = true } }
        }
        if !settings.hasCompletedFirstLaunch {
            model.perform { try model.ledger.updateSettings { $0.hasCompletedFirstLaunch = true } }
            if !model.ledger.hasPendingRecovery { showCalendar() }
        }
    }

    private func fatalStartupError(_ error: Error) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Workday couldn't open its data"
        alert.informativeText = "\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)\n\nYour data has not been changed. Backups are in \(WorkdayPaths.backupsDirectory.path)."
        alert.addButton(withTitle: "Show Data Folder")
        alert.addButton(withTitle: "Quit")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([WorkdayPaths.dataDirectory])
        }
        NSApp.terminate(nil)
    }

    // MARK: Timers & OS signals

    private func startTimers() {
        // Display refresh: 1 s. Accrual never depends on this timer.
        let display = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.displayTick() }
        }
        display.tolerance = 0.2
        RunLoop.main.add(display, forMode: .common)
        displayTimer = display

        let heartbeat = Timer(timeInterval: Self.heartbeatInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.ledger.checkpoint(kind: .heartbeat) }
        }
        heartbeat.tolerance = 5
        RunLoop.main.add(heartbeat, forMode: .common)
        heartbeatTimer = heartbeat

        let maintenance = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.runAutomaticBackup() }
        }
        maintenance.tolerance = 120
        RunLoop.main.add(maintenance, forMode: .common)
        maintenanceTimer = maintenance
    }

    private var lastReminderCheck = Date.distantPast

    private func displayTick() {
        let previousDay = model.today
        model.tick()
        if model.today != previousDay { model.ledger.setCalendar(.autoupdatingCurrent) }
        statusItem.update()
        if Date().timeIntervalSince(lastReminderCheck) >= 15 {
            lastReminderCheck = Date()
            model.evaluateReminders()
        }
    }

    /// Called after Start/Stop/recovery changes.
    func timerStateChanged() {
        statusItem?.update()
        if model.isRunning {
            if napActivity == nil {
                // Keep timers and checkpoints timely; idle system sleep is still allowed.
                napActivity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep],
                                                                    reason: "Workday timer running")
            }
        } else if let activity = napActivity {
            ProcessInfo.processInfo.endActivity(activity)
            napActivity = nil
        }
    }

    private func observeSystem() {
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.ledger.checkpoint(kind: .sleep) }
        }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // The process survived sleep: the session continued, so sleep time counts (no prompt).
                self.model.ledger.checkpoint(kind: .wake)
                self.model.ledger.setCalendar(.autoupdatingCurrent)
                self.displayTick()
                self.model.runAutomaticBackup()
            }
        }
        ws.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.poweringOff = true
                self?.model.ledger.checkpoint(kind: .shutdown)
            }
            // If the logout/shutdown is cancelled by another app we keep running: re-arm the quit
            // confirmation after a grace period.
            DispatchQueue.main.asyncAfter(deadline: .now() + 90) {
                MainActor.assumeIsolated { self?.poweringOff = false }
            }
        }
        DistributedNotificationCenter.default().addObserver(forName: Self.showCalendarNotification,
                                                            object: Self.instanceToken, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.showCalendar() }
        }
        let nc = NotificationCenter.default
        for name in [NSNotification.Name.NSSystemTimeZoneDidChange, .NSCalendarDayChanged, NSLocale.currentLocaleDidChangeNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.model.ledger.setCalendar(.autoupdatingCurrent)
                    self?.displayTick()
                }
            }
        }
    }

    // MARK: Termination

    /// True when macOS is quitting us for a logout, restart or shutdown (kAEQuitReason on the quit event).
    private var isSystemQuit: Bool {
        func fourCC(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              let reason = event.attributeDescriptor(forKeyword: fourCC("why?"))?.enumCodeValue else { return false }
        return ["logo", "rlgo", "rrst", "rsdn", "rest", "shut"].map(fourCC).contains(reason)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isSystemQuit {
            poweringOff = true
            model?.ledger.checkpoint(kind: .shutdown)
        }
        guard let model, model.isRunning, !poweringOff else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "The timer is running"
        alert.informativeText = "Quitting Workday stops tracking. Stop the timer now (recording \(DurationFormat.short(model.ledger.activeElapsed())) for this session) and quit?"
        alert.addButton(withTitle: "Stop Timer & Quit")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            model.stop()
            if model.isRunning {
                // The stop failed (e.g. the clock moved backwards): stay open so the user sees why.
                let failure = NSAlert()
                failure.messageText = "The timer couldn't be stopped"
                failure.informativeText = model.errorMessage ?? "Please try again."
                failure.runModal()
                return .terminateCancel
            }
            return .terminateNow
        }
        return .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        if poweringOff { model?.ledger.checkpoint(kind: .shutdown) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showCalendar()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: Windows & Dock policy

    func showCalendar(day: DayKey? = nil) {
        statusItem?.closePopover()
        if calendarWindow == nil {
            let root = CalendarRootView().environment(model)
            let window = makeWindow(title: "Workday", content: root, size: NSSize(width: 1060, height: 800),
                                    minSize: NSSize(width: 760, height: 620), autosave: "WorkdayCalendar")
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.isMovableByWindowBackground = true
            calendarWindow = window
        }
        if let day { model.requestedDay = day }
        present(calendarWindow!)
    }

    func showSettings() {
        statusItem?.closePopover()
        if settingsWindow == nil {
            let root = SettingsView().environment(model)
            settingsWindow = makeWindow(title: "Workday Settings", content: root, size: NSSize(width: 620, height: 560),
                                        minSize: NSSize(width: 560, height: 480), autosave: "WorkdaySettings")
            settingsWindow?.styleMask.remove(.miniaturizable)
        }
        present(settingsWindow!)
    }

    /// The recovery panel does not force the Dock icon or the calendar open.
    func showRecovery() {
        statusItem?.closePopover()
        if recoveryWindow == nil {
            let root = RecoveryView().environment(model)
            let window = makeWindow(title: "Interrupted Session", content: root, size: NSSize(width: 560, height: 600),
                                    minSize: NSSize(width: 520, height: 480), autosave: nil)
            window.styleMask.remove(.miniaturizable)
            window.level = .normal
            recoveryWindow = window
        }
        recoveryWindow?.center()
        NSApp.activate(ignoringOtherApps: true)
        recoveryWindow?.makeKeyAndOrderFront(nil)
    }

    func closeRecovery() {
        recoveryWindow?.close()
    }

    private func makeWindow<V: View>(title: String, content: V, size: NSSize, minSize: NSSize, autosave: String?) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = title
        let host = NSHostingController(rootView: content)
        // Window sizes are explicit (size + contentMinSize below). Letting SwiftUI derive them from wrapping
        // text measured at a near-zero width produced absurdly tall windows.
        host.sizingOptions = []
        window.contentViewController = host
        window.setContentSize(size)
        window.contentMinSize = minSize
        window.isReleasedWhenClosed = false
        window.delegate = self
        if let autosave {
            window.setFrameAutosaveName(autosave)
            if !window.setFrameUsingName(autosave) { window.center() }
        } else {
            window.center()
        }
        return window
    }

    private func present(_ window: NSWindow) {
        updateDockPolicy(opening: true)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        if window === calendarWindow { model.calendarVisible = true }
    }

    /// Dock icon is visible only while the calendar or settings window is open.
    private func updateDockPolicy(opening: Bool = false) {
        let visible = [calendarWindow, settingsWindow].contains { $0?.isVisible == true }
        let wanted: NSApplication.ActivationPolicy = (opening || visible) ? .regular : .accessory
        if NSApp.activationPolicy() != wanted {
            NSApp.setActivationPolicy(wanted)
            if wanted == .regular { NSApp.activate(ignoringOtherApps: true) }
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === calendarWindow { model.calendarVisible = false }
        DispatchQueue.main.async { [weak self] in
            self?.updateDockPolicy()
        }
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === calendarWindow else { return }
        model.calendarVisible = window.occlusionState.contains(.visible) && window.isVisible
    }

    func windowDidMiniaturize(_ notification: Notification) {
        if (notification.object as? NSWindow) === calendarWindow { model.calendarVisible = false }
    }

    // MARK: Main menu

    private func buildMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Workday", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(menuSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Workday", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Workday", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let timerItem = NSMenuItem()
        let timerMenu = NSMenu(title: "Timer")
        timerMenu.addItem(withTitle: "Start Timer", action: #selector(menuToggleTimer), keyEquivalent: "s").keyEquivalentModifierMask = [.command, .shift]
        timerMenu.items.last?.target = self
        timerMenu.items.last?.tag = Self.timerMenuTag
        timerItem.submenu = timerMenu
        main.addItem(timerItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Calendar", action: #selector(menuCalendar), keyEquivalent: "0").target = self
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = main
    }

    private static let timerMenuTag = 4242

    /// Keeps the timer menu item's title explicit about what it will do.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.tag == Self.timerMenuTag {
            menuItem.title = model?.isRunning == true
                ? "Stop Timer (records \(DurationFormat.short(model.ledger.activeElapsed())))"
                : "Start Timer"
        }
        return true
    }

    @objc private func menuSettings() { showSettings() }
    @objc private func menuCalendar() { showCalendar() }
    @objc private func menuToggleTimer() {
        // Menu-key toggle asks nothing: the item title makes the consequence explicit.
        model.isRunning ? model.stop() : model.start()
    }
}
