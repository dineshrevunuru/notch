import AppKit
import SwiftUI

/// The full task window. The app stays out of the Dock until this opens,
/// then joins the Dock and ⌘-Tab while it's open, and leaves again when it closes.
final class TaskWindowController: NSObject, NSWindowDelegate {
    private let model: NotchModel
    private var window: NSWindow?

    init(model: NotchModel) {
        self.model = model
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        model.tasks.reloadIfChangedOnDisk()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let controller = NSHostingController(rootView: TaskAppView(model: model))
        controller.sizingOptions = [.minSize]
        let window = NSWindow(contentViewController: controller)
        window.title = "Tasks"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 820, height: 520)
        if !window.setFrameUsingName("NotchTasksWindow") {
            window.setContentSize(NSSize(width: 1120, height: 720))
            window.center()
        }
        window.setFrameAutosaveName("NotchTasksWindow")
        return window
    }

    func windowWillClose(_ notification: Notification) {
        model.tasks.saveNow()
        NSApp.setActivationPolicy(.accessory)
    }
}
