import AppKit
import EventKit
import NotchCore
import ServiceManagement

/// Which build this is. The Mac App Store edition runs in the App Sandbox, where Notch can't ask
/// browsers for their tabs, so Focus Guard watches apps (games, video players) but not websites.
/// Everything else is the same.
enum Edition {
    static let isAppStore = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil

    /// What Focus Guard can recognize in this edition.
    static var supportedKinds: [DistractionKind] {
        isAppStore ? [.game, .video] : DistractionKind.allCases
    }
}

/// `Notch --selftest`: checks the things the sandbox could break, without opening a window or
/// asking for any permission, prints the results, and exits.
enum SelfTest {
    static func run() -> Never {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        var failures = 0
        func report(_ name: String, _ ok: Bool, _ detail: String) {
            if !ok { failures += 1 }
            print("\(ok ? "PASS" : "FAIL")  \(name): \(detail)")
        }

        report("edition", true, Edition.isAppStore ? "App Store (sandboxed)" : "direct download (not sandboxed)")

        // Tasks are saved in Application Support; in the sandbox that's inside the app's container.
        let storeURL = TaskStore.defaultFileURL
        let probe = storeURL.deletingLastPathComponent().appendingPathComponent("selftest-\(UUID().uuidString).json")
        do {
            try FileManager.default.createDirectory(at: probe.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: probe)
            let back = try Data(contentsOf: probe)
            try FileManager.default.removeItem(at: probe)
            report("task storage", back == Data("{}".utf8), storeURL.deletingLastPathComponent().path)
        } catch {
            report("task storage", false, error.localizedDescription)
        }

        // Focus Guard recognizes games by reading an app's category from its bundle.
        let chess = URL(fileURLWithPath: "/System/Applications/Chess.app")
        let category = Bundle(url: chess)?.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String
        let game = DistractionRules.classify(bundleID: "com.apple.Chess", appName: "Chess", appCategory: category, url: nil, kinds: [.game])
        report("game detection", game?.kind == .game, "Chess category \(category ?? "unreadable")")

        report("front app", NSWorkspace.shared.frontmostApplication != nil, NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none")

        let calendar: String = switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: "allowed"
        case .notDetermined: "not asked yet"
        case .denied: "denied"
        default: "other"
        }
        report("calendar permission readable", true, calendar)

        let login: String = switch SMAppService.mainApp.status {
        case .enabled: "on"
        case .notRegistered: "off"
        case .requiresApproval: "needs approval"
        case .notFound: "not found"
        @unknown default: "unknown"
        }
        report("open at login readable", true, login)

        printScreens()
        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    /// What macOS says about each screen's top edge, and where Notch would draw. Run on a Mac we
    /// can't test on (the MacBook Pro with Dynamic Island, say), this shows whether Notch would
    /// sit on top of the system's own island.
    private static func printScreens() {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [UInt8](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        print("INFO  model: \(String(decoding: model.prefix { $0 != 0 }, as: UTF8.self))")

        for screen in NSScreen.screens {
            let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
            let frame = screen.frame
            func rect(_ r: CGRect?) -> String {
                guard let r else { return "none" }
                return "\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))×\(Int(r.height))"
            }
            print("INFO  screen \"\(screen.localizedName)\"\(CGDisplayIsBuiltin(id) != 0 ? " (built-in)" : ""): "
                + "\(Int(frame.width))×\(Int(frame.height)) pt, scale \(screen.backingScaleFactor), "
                + "safe-area top \(screen.safeAreaInsets.top), menu bar \(Int(frame.maxY - screen.visibleFrame.maxY)), "
                + "left of camera \(rect(screen.auxiliaryTopLeftArea)), right of camera \(rect(screen.auxiliaryTopRightArea))")
        }

        let metrics = NotchMetrics.current()
        let where_ = metrics.hasHardwareNotch ? "around the camera notch" : "as a stand-in at the top center"
        print("INFO  Notch would draw \(where_): \(Int(metrics.notchSize.width))×\(Int(metrics.notchSize.height)) pt, "
            + "centered at x \(Int(metrics.notchCenterX))")
    }
}
