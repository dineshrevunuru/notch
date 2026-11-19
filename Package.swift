// swift-tools-version: 6.2
import PackageDescription

// UI code runs on the main actor by default; pure value types opt out with `nonisolated`.
let mainActorByDefault: [SwiftSetting] = [.defaultIsolation(MainActor.self)]

let package = Package(
    name: "Notch",
    platforms: [.macOS(.v14)],
    targets: [
        // Logic with no AppKit: status lines, the task list, the focus timer.
        .target(
            name: "NotchCore",
            path: "Sources/NotchCore",
            swiftSettings: mainActorByDefault
        ),
        // The app: the panel over the notch, hover handling, SwiftUI views, EventKit.
        .executableTarget(
            name: "Notch",
            dependencies: ["NotchCore"],
            path: "Sources/Notch",
            swiftSettings: mainActorByDefault
        ),
        .testTarget(
            name: "NotchCoreTests",
            dependencies: ["NotchCore"],
            path: "Tests/NotchCoreTests",
            swiftSettings: mainActorByDefault
        ),
    ]
)
