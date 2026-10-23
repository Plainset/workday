// swift-tools-version:6.0
import Foundation
import PackageDescription

// With only the Command Line Tools installed (no Xcode), the Swift Testing framework lives outside
// the default search paths. Point the test target at it when the CLT is the active developer dir.
let cltFrameworks = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
let activeDeveloperDir = (try? FileManager.default.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link"))
    ?? (FileManager.default.fileExists(atPath: "/Applications/Xcode.app") ? "/Applications/Xcode.app" : "/Library/Developer/CommandLineTools")
let useCLTTesting = activeDeveloperDir.hasPrefix("/Library/Developer/CommandLineTools")
    && FileManager.default.fileExists(atPath: cltFrameworks + "/Testing.framework")
let testSwiftSettings: [SwiftSetting] = useCLTTesting ? [.unsafeFlags(["-F", cltFrameworks])] : []
let testLinkerSettings: [LinkerSetting] = useCLTTesting
    ? [.unsafeFlags(["-F", cltFrameworks,
                     "-Xlinker", "-rpath", "-Xlinker", cltFrameworks,
                     "-Xlinker", "-rpath", "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"])] : []

let package = Package(
    name: "Workday",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Workday", targets: ["Workday"]),
        .library(name: "WorkdayCore", targets: ["WorkdayCore"]),
    ],
    targets: [
        // Pure domain, persistence, recovery, backup and time-accounting logic. No UI.
        .target(
            name: "WorkdayCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // AppKit + SwiftUI application: menu bar, calendar, editor, settings.
        .executableTarget(
            name: "Workday",
            dependencies: ["WorkdayCore"],
            linkerSettings: [
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UserNotifications"),
            ]
        ),
        .testTarget(
            name: "WorkdayCoreTests",
            dependencies: ["WorkdayCore"],
            swiftSettings: testSwiftSettings,
            linkerSettings: testLinkerSettings
        ),
    ],
    swiftLanguageModes: [.v5]
)
