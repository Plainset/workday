import AppKit
import Observation
import WorkdayCore

/// Runs folder sync for the app: when to sync (launch, wake, every ~45 s while on, shortly after a local
/// change), the on/off switch, the folder and device name, and the status shown in Settings.
/// Sync is off by default; while off it does no work at all.
@MainActor
@Observable
final class SyncController {
    enum Status: Equatable {
        case off
        case syncing
        case ok
        case failed(String)
    }

    private(set) var status: Status = .off
    private(set) var enabled: Bool
    private(set) var folder: URL
    private(set) var deviceName: String
    private(set) var lastSynced: Date?
    private(set) var peers: [SyncPeer] = []
    private(set) var problems: [String] = []

    @ObservationIgnored private let engine: SyncEngine
    @ObservationIgnored private var store: WorkStore { engine.ledger.store }
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var pending: DispatchWorkItem?
    @ObservationIgnored private let interval: TimeInterval
    /// Called after a pass that changed local data.
    @ObservationIgnored var onChange: ((SyncReport) -> Void)?

    static let defaultInterval: TimeInterval = 45

    init(ledger: WorkLedger) {
        engine = SyncEngine(ledger: ledger)
        let store = ledger.store
        enabled = store.meta("sync_enabled") == "1"
        folder = store.meta("sync_folder_path").map { URL(fileURLWithPath: $0, isDirectory: true) } ?? SyncEngine.iCloudDriveURL
        deviceName = store.meta("sync_device_name") ?? ""
        lastSynced = Double(store.meta("sync_last_success") ?? "").map(Date.init(timeIntervalSinceReferenceDate:))
        var interval = Self.defaultInterval
        // Test and demo instances (custom data folder) can sync with a temporary folder, faster.
        let env = ProcessInfo.processInfo.environment
        if WorkdayPaths.usesCustomDataDirectory {
            if let dir = env["WORKDAY_SYNC_DIR"], !dir.isEmpty {
                enabled = true
                folder = URL(fileURLWithPath: dir, isDirectory: true)
            }
            if let seconds = env["WORKDAY_SYNC_INTERVAL"].flatMap(Double.init), seconds >= 1 { interval = seconds }
        }
        self.interval = interval
        if deviceName.isEmpty { deviceName = Self.defaultDeviceName }
    }

    static var defaultDeviceName: String {
        if let name = env("WORKDAY_DEVICE_NAME") { return SyncValidation.cleanName(name) }
        let name = SyncValidation.cleanName(Host.current().localizedName ?? "")
        return name.isEmpty ? "Mac" : name
    }

    private static func env(_ key: String) -> String? {
        guard WorkdayPaths.usesCustomDataDirectory, let v = ProcessInfo.processInfo.environment[key], !v.isEmpty else { return nil }
        return v
    }

    var isUsingICloudDrive: Bool { folder.standardizedFileURL.path == SyncEngine.iCloudDriveURL.standardizedFileURL.path }
    static var iCloudDriveAvailable: Bool { FileManager.default.fileExists(atPath: SyncEngine.iCloudDriveURL.path) }

    /// Name of another Mac for display ("your other Mac" if it hasn't been seen yet).
    func name(of device: String) -> String {
        peers.first { $0.id == device }?.name ?? "your other Mac"
    }

    // MARK: Lifecycle

    /// Called once at launch.
    func start() {
        guard enabled else { status = .off; return }
        scheduleTimer()
        syncNow()
    }

    /// Turns sync on. A safety backup is made first, so the first merge can always be undone.
    func enable(backups: BackupManager) -> String? {
        do {
            try backups.createBackup(kind: .safety)
        } catch {
            return "Sync wasn't turned on because the safety backup failed: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
        }
        try? store.setMeta("sync_enabled", "1")
        try? store.setMeta("sync_folder_path", folder.path)
        try? store.setMeta("sync_device_name", deviceName)
        enabled = true
        scheduleTimer()
        syncNow()
        return nil
    }

    /// Turns sync off: nothing is read or written any more; all local data stays.
    func disable() {
        try? store.setMeta("sync_enabled", "0")
        enabled = false
        timer?.invalidate()
        timer = nil
        pending?.cancel()
        pending = nil
        status = .off
        problems = []
    }

    func setFolder(_ url: URL) {
        folder = url
        try? store.setMeta("sync_folder_path", url.path)
        peers = []
        if enabled { syncNow() }
    }

    func setDeviceName(_ name: String) {
        let clean = SyncValidation.cleanName(name)
        guard !clean.isEmpty, clean != deviceName else { return }
        deviceName = clean
        try? store.setMeta("sync_device_name", clean)
        if enabled { scheduleSoon() }
    }

    // MARK: Passes

    private func scheduleTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncNow() }
        }
        t.tolerance = min(10, interval / 4)
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Syncs shortly after a local change, coalescing bursts of edits into one pass.
    func scheduleSoon() {
        guard enabled else { return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.syncNow() }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    func syncNow() {
        guard enabled else { return }
        pending?.cancel()
        pending = nil
        do {
            let report = try engine.sync(folder: folder, deviceName: deviceName)
            lastSynced = report.completedAt
            if peers != report.peers { peers = report.peers }
            if problems != report.problems { problems = report.problems }
            if status != .ok { status = .ok }
            if report.applied > 0 || report.localTimerChanged { onChange?(report) }
        } catch let error as SyncError {
            var message = error.errorDescription ?? "\(error)"
            if case .folderMissing = error, !isUsingICloudDrive {
                message = "The sync folder “\(folder.lastPathComponent)” can't be found. Reconnect the drive or choose the folder again."
            }
            status = .failed(message)
        } catch {
            status = .failed("Sync couldn't finish: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription). Your data on this Mac is unchanged.")
        }
    }
}
