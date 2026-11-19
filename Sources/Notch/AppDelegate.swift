import AppKit
import NotchCore
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = NotchModel()
    private lazy var controller = NotchController(model: model)
    private lazy var taskWindow = TaskWindowController(model: model)
    private lazy var distractionMonitor = DistractionMonitor(model: model)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make(openTasks: #selector(openTasks))
        model.openTasksWindow = { [weak self] in
            self?.controller.setExpanded(false)
            self?.taskWindow.show()
        }
        controller.show()
        model.start()
        distractionMonitor.start()
    }

    /// Launching Notch again (Spotlight, Finder, the Dock) opens the task window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        taskWindow.show()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.tasks.saveNow()
    }

    /// Turns Open at Login on or off, and records the result so it can be checked from outside.
    private func setOpensAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSSound.beep()
        }
        let status: String = switch SMAppService.mainApp.status {
        case .enabled: "enabled"
        case .requiresApproval: "requires approval"
        case .notRegistered: "not registered"
        case .notFound: "not found"
        @unknown default: "unknown"
        }
        UserDefaults.standard.set(status, forKey: "loginItemStatus")
    }

    @objc func openTasks() {
        taskWindow.show()
    }

    /// `notch://` links, so Shortcuts, Raycast or your own scripts can drive the notch:
    ///   notch://open · notch://close · notch://toggle · notch://tasks · notch://planner
    ///   notch://login?enabled=true|false  (only the app itself can add itself as a login item)
    ///   notch://focus (next Pomodoro round) · notch://focus?minutes=50 · notch://focus/pause · /skip · /stop
    ///   notch://add?title=Send%20invoice&project=Client&due=tomorrow   (due: today, tomorrow, 2026-11-20, 2026-11-20T15:00)
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { handle(url) }
    }

    private func handle(_ url: URL) {
        guard url.scheme == "notch", let action = url.host() else { return }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }

        switch action {
        case "open": controller.setExpanded(true)
        case "close": controller.setExpanded(false)
        case "toggle": controller.setExpanded(!model.isExpanded)
        case "tasks": taskWindow.show()
        case "planner": model.openPlanner()
        case "guard-check": distractionMonitor.check()
        case "login": setOpensAtLogin(value("enabled") != "false")
        case "focus":
            switch url.path() {
            case "/stop": model.stopFocus()
            case "/pause": if !model.pomodoro.isPaused { model.togglePause() }
            case "/resume": if model.pomodoro.isPaused { model.togglePause() }
            case "/skip": model.skipPhase()
            default: model.startFocus(minutes: value("minutes").flatMap(Int.init))
            }
        case "add":
            guard let title = value("title") else { return }
            let project = value("project").flatMap { name in model.tasks.project(named: name) ?? model.tasks.addProject(name) }
            model.tasks.add(title, project: project?.id, due: value("due").flatMap(LinkDate.parse))
        default:
            break
        }
    }
}

/// Dates in `notch://add` links.
enum LinkDate {
    static func parse(_ text: String) -> DueDate? {
        let calendar = Calendar.current
        switch text.lowercased() {
        case "today": return .day(.now)
        case "tomorrow": return calendar.date(byAdding: .day, value: 1, to: .now).map { .day($0) }
        default: break
        }
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
        if let date = day.date(from: text) { return .day(date) }
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.dateFormat = "yyyy-MM-dd'T'HH:mm"
        if let date = local.date(from: text) { return DueDate(date: date, hasTime: true) }
        if let date = ISO8601DateFormatter().date(from: text) { return DueDate(date: date, hasTime: true) }
        return nil
    }
}

/// The menu bar shown while the task window is open. The Edit menu is what makes
/// copy, paste and undo work in every text field, the notch's included.
enum MainMenu {
    static func make(openTasks: Selector) -> NSMenu {
        let main = NSMenu()

        let app = NSMenu(title: "Notch")
        app.addItem(withTitle: "About Notch", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Notch", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Notch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu(app))

        let file = NSMenu(title: "File")
        file.addItem(withTitle: "Show Tasks", action: openTasks, keyEquivalent: "t")
        file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(submenu(file))

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu(edit))

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        main.addItem(submenu(window))
        NSApp.windowsMenu = window

        return main
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}
