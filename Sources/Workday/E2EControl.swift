import Foundation
import WorkdayCore

/// Test harness for the two-instance sync check (`scripts/sync_e2e.sh`). Active only with `--e2e-control`
/// and a custom `WORKDAY_DATA_DIR`, like `--perf` and `--memtest`: it reads one command at a time from
/// `<data dir>/e2e-command` and writes the visible state to `<data dir>/e2e-state.json`.
///
/// Commands: `start`, `stop`, `takeover`, `add <start> <end>`, `edit <uuid> <start> <end>`, `delete <uuid>`,
/// `goal <minutes>`, `sync` (times are seconds since the reference date).
@MainActor
enum E2EControl {
    private static var timer: Timer?
    private static var lastResult = "idle"

    static func start(model: AppModel) {
        let dir = WorkdayPaths.dataDirectory
        let t = Timer(timeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated { step(model: model, dir: dir) }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private static func step(model: AppModel, dir: URL) {
        let commandURL = dir.appendingPathComponent("e2e-command")
        if let text = try? String(contentsOf: commandURL, encoding: .utf8) {
            try? FileManager.default.removeItem(at: commandURL)
            lastResult = run(text.trimmingCharacters(in: .whitespacesAndNewlines), model: model)
        }
        writeState(model: model, dir: dir, result: lastResult)
    }

    private static func run(_ command: String, model: AppModel) -> String {
        let parts = command.split(separator: " ").map(String.init)
        let ledger = model.ledger
        func time(_ s: String) -> Date? { Double(s).map(Date.init(timeIntervalSinceReferenceDate:)) }
        let ok: Bool
        switch parts.first {
        case "start": ok = model.perform { try ledger.start() }
        case "stop": ok = model.perform { try ledger.stop() }
        case "takeover":
            guard let remote = ledger.remoteActiveSessions.first else { return "error: nothing running elsewhere" }
            ok = model.perform { try ledger.stopRemoteAndStart(remoteID: remote.id) }
        case "add":
            guard parts.count == 3, let s = time(parts[1]), let e = time(parts[2]) else { return "error: usage" }
            ok = model.perform { try ledger.addSession(start: s, end: e) }
        case "edit":
            guard parts.count == 4, let id = UUID(uuidString: parts[1]), let s = time(parts[2]), let e = time(parts[3]) else { return "error: usage" }
            ok = model.perform { try ledger.updateSession(id: id, start: s, end: e) }
        case "delete":
            guard parts.count == 2, let id = UUID(uuidString: parts[1]) else { return "error: usage" }
            ok = model.perform { try ledger.deleteSession(id: id) }
        case "goal":
            guard parts.count == 2, let m = Int(parts[1]) else { return "error: usage" }
            ok = model.perform { try ledger.updateSettings { $0.dailyGoalMinutes = m } }
        case "sync":
            model.sync.syncNow()
            ok = true
        default:
            return "error: unknown command"
        }
        if ok { model.sync.syncNow() }
        return ok ? "ok: \(command)" : "error: \(model.errorMessage ?? "failed")"
    }

    private static func writeState(model: AppModel, dir: URL, result: String) {
        let ledger = model.ledger
        let sessions: [[String: Any]] = ledger.sessions.map { s in
            ["id": s.id.uuidString, "start": s.start.timeIntervalSinceReferenceDate,
             "end": s.end?.timeIntervalSinceReferenceDate ?? -1, "state": s.state.rawValue,
             "local": ledger.isLocal(s)]
        }
        var status = "off"
        switch model.sync.status {
        case .off: status = "off"
        case .syncing: status = "syncing"
        case .ok: status = "ok"
        case .failed(let m): status = "failed: \(m)"
        }
        let state: [String: Any] = [
            "result": result,
            "device": ledger.deviceID,
            "running": ledger.isRunning,
            "runningElsewhere": ledger.remoteActiveSessions.map { model.remoteName($0) },
            "goalMinutes": ledger.settings.dailyGoalMinutes,
            "todaySeconds": ledger.total(for: ledger.today()),
            "sessions": sessions,
            "peers": model.sync.peers.map(\.name),
            "syncStatus": status,
            "problems": model.sync.problems,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) else { return }
        let url = dir.appendingPathComponent("e2e-state.json")
        let tmp = dir.appendingPathComponent(".e2e-state.tmp")
        if FileManager.default.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) {
            _ = rename(tmp.path, url.path)
        }
    }
}
