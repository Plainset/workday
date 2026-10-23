import AppKit
import WorkdayCore

// `Workday --snapshot <dir>` renders evidence images from deterministic demo data and exits.
if let index = CommandLine.arguments.firstIndex(of: "--snapshot") {
    let dir = CommandLine.arguments.count > index + 1 ? CommandLine.arguments[index + 1] : "snapshots"
    MainActor.assumeIsolated {
        SnapshotRenderer.run(outputDirectory: URL(fileURLWithPath: dir))
    }
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) {
        app.run()
    }
}
