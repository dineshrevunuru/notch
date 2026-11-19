import AppKit
import NotchCore
import os

/// Focus Guard's own log: what it saw and why it did or didn't nudge. Only site names, never
/// full addresses. Read it with: log show --last 30m --predicate 'subsystem == "com.dineshrevunuru.notch"'
nonisolated let guardLog = Logger(subsystem: "com.dineshrevunuru.notch", category: "focus-guard")

/// Looks at what's in front every 20 seconds and on every app switch, only while a nudge could
/// apply (Focus Guard on, a focus round or your workday). It reads the app's name and category,
/// and for Chrome and Safari the address of the active tab. It never sees the screen, and nothing
/// it reads leaves the Mac; only a name like "YouTube" and the minutes are kept, for the wrap-up.
final class DistractionMonitor {
    private let model: NotchModel
    private var loop: Task<Void, Never>?
    private let scripts = DispatchQueue(label: "notch.browser-address", qos: .utility)
    /// Browsers that said no to being asked: don't keep asking.
    private var refused: Set<String> = []

    init(model: NotchModel) {
        self.model = model
    }

    func start() {
        // Know up front whether a browser is blocked, so the menu can say so before you notice.
        check()
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.look() }
        }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                self?.look()
                try? await Task.sleep(for: .seconds(20))
            }
        }
    }

    private func look() {
        guard model.distractionSettings.enabled, model.distractionContext != .off,
              let app = NSWorkspace.shared.frontmostApplication else {
            guardLog.debug("idle: enabled=\(self.model.distractionSettings.enabled) context=\(String(describing: self.model.distractionContext))")
            model.observeDistraction(nil)
            return
        }
        let bundleID = app.bundleIdentifier
        let name = app.localizedName
        let category = app.bundleURL.flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String }
        let kinds = model.distractionSettings.kinds

        guard let bundleID, let source = Browser.script(for: bundleID), !refused.contains(bundleID) else {
            let found = DistractionRules.classify(bundleID: bundleID, appName: name, appCategory: category, url: nil, kinds: kinds)
            guardLog.info("front app \(bundleID ?? "?", privacy: .public): \(found?.name ?? "not a distraction", privacy: .public)")
            model.observeDistraction(found)
            return
        }

        scripts.async { [weak self] in
            let result = Browser.run(source)
            Task { @MainActor in
                guard let self else { return }
                let url: String?
                switch result {
                case .address(let address):
                    url = address
                    self.model.browsersWithoutAccess.remove(Browser.name(bundleID))
                case .refused:
                    url = nil
                    self.refused.insert(bundleID)
                    self.model.browsersWithoutAccess.insert(Browser.name(bundleID))
                    guardLog.error("\(bundleID, privacy: .public) refused: Automation permission is off in System Settings")
                case .failed(let code):
                    url = nil
                    guardLog.error("\(bundleID, privacy: .public) tab address failed: AppleScript error \(code, privacy: .public)")
                case .nothing:
                    url = nil
                }
                let found = DistractionRules.classify(bundleID: bundleID, appName: name, appCategory: category, url: url, kinds: kinds)
                let host = url.flatMap(DistractionRules.host(of:)) ?? "no address"
                guardLog.info("\(bundleID, privacy: .public) at \(host, privacy: .public): \(found?.name ?? "not a distraction", privacy: .public)")
                self.model.observeDistraction(found)
            }
        }
    }

    /// `notch://guard-check`: logs, for each running browser, whether Notch may ask it for its
    /// tab address, and what it gets when it does. Doesn't need the browser in front.
    func check() {
        for bundleID in ["com.google.Chrome", "com.apple.Safari"] {
            guard let source = Browser.script(for: bundleID) else { continue }
            let permission = Browser.permission(for: bundleID)
            guardLog.notice("check \(bundleID, privacy: .public): permission \(permission, privacy: .public)")
            if permission == "denied" {
                model.browsersWithoutAccess.insert(Browser.name(bundleID))
            } else if permission == "granted" {
                model.browsersWithoutAccess.remove(Browser.name(bundleID))
                refused.remove(bundleID)
            }
            scripts.async {
                let result = Browser.run(source)
                let summary: String = switch result {
                case .address(let address): "address ok (\(DistractionRules.host(of: address) ?? "?"))"
                case .nothing: "no window"
                case .refused: "refused (-1743)"
                case .failed(let code): "failed (\(code))"
                }
                guardLog.notice("check \(bundleID, privacy: .public): \(summary, privacy: .public)")
            }
        }
    }
}

/// Asking a browser for its active tab's address.
enum Browser {
    enum Result: Sendable {
        case address(String)
        case nothing
        case refused
        case failed(Int)
    }

    nonisolated static func name(_ bundleID: String) -> String {
        bundleID == "com.apple.Safari" ? "Safari" : "Chrome"
    }

    /// Opens System Settings at Privacy & Security › Automation, where the switch lives.
    @MainActor static func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Whether macOS lets Notch send this browser Apple Events, without asking.
    nonisolated static func permission(for bundleID: String) -> String {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let desc = target.aeDesc else { return "unknown" }
        let status = AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, false)
        switch status {
        case noErr: return "granted"
        case OSStatus(errAEEventNotPermitted): return "denied"
        case OSStatus(errAEEventWouldRequireUserConsent): return "not asked yet"
        case OSStatus(procNotFound): return "browser not running"
        default: return "status \(status)"
        }
    }

    /// Chrome and Safari. Firefox can't be asked this way.
    nonisolated static func script(for bundleID: String) -> String? {
        switch bundleID {
        case "com.google.Chrome":
            return #"with timeout of 2 seconds\#ntell application id "com.google.Chrome" to if (count of windows) > 0 then get URL of active tab of front window\#nend timeout"#
        case "com.apple.Safari":
            return #"with timeout of 2 seconds\#ntell application id "com.apple.Safari" to if (count of windows) > 0 then get URL of current tab of front window\#nend timeout"#
        default:
            return nil
        }
    }

    /// Runs on a background queue: macOS may show its one-time permission prompt, and a busy
    /// browser can take a moment, neither of which should ever hold up the notch.
    nonisolated static func run(_ source: String) -> Result {
        var error: NSDictionary?
        let output = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let code = error?[NSAppleScript.errorNumber] as? Int {
            return code == -1743 ? .refused : .failed(code) // -1743: you said no to this in System Settings
        }
        guard let address = output?.stringValue, !address.isEmpty else { return .nothing }
        return .address(address)
    }
}
