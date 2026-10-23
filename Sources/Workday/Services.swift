import AppKit
import ServiceManagement
import UserNotifications
import WorkdayCore

/// Local notifications (goal reached, start/stop reminders). Nothing ever leaves the Mac.
@MainActor
@Observable
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    enum Permission: Equatable {
        case unavailable   // not running from an app bundle
        case notDetermined
        case denied
        case authorized
    }

    private(set) var permission: Permission = .notDetermined

    /// UNUserNotificationCenter crashes outside a bundled app, so guard every use.
    var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    override init() {
        super.init()
        if isAvailable {
            UNUserNotificationCenter.current().delegate = self
        } else {
            permission = .unavailable
        }
    }

    func refresh() async {
        guard isAvailable else { permission = .unavailable; return }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: permission = .authorized
        case .denied: permission = .denied
        case .notDetermined: permission = .notDetermined
        @unknown default: permission = .denied
        }
    }

    /// Asks for permission (only when a notification feature is enabled). Denial is handled gracefully.
    @discardableResult
    func requestAuthorization() async -> Bool {
        guard isAvailable else { return false }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        await refresh()
        return permission == .authorized
    }

    func post(id: String, title: String, body: String) {
        guard isAvailable, permission == .authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        // Stable identifiers mean a repeated request replaces rather than duplicates.
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in AppDelegate.shared?.showCalendar() }
        completionHandler()
    }
}

/// Launch-at-login via `SMAppService.mainApp` with user-visible status.
@MainActor
@Observable
final class LaunchAtLogin {
    enum State: Equatable {
        case enabled
        case disabled
        case requiresApproval
        case unavailable(String)
    }

    private(set) var state: State = .disabled
    private(set) var lastError: String?

    var isBundled: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    func refresh() {
        guard isBundled else {
            state = .unavailable("Launch at login is available when Workday runs as an installed app.")
            return
        }
        switch SMAppService.mainApp.status {
        case .enabled: state = .enabled
        case .requiresApproval: state = .requiresApproval
        case .notRegistered, .notFound: state = .disabled
        @unknown default: state = .disabled
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard isBundled else { refresh(); return }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
