import AppKit
import SwiftUI

/// A borderless panel that sits over the menu bar, on every Space and over full-screen apps.
/// It never activates the app, so hovering the notch doesn't steal focus from what you're doing;
/// it only takes keyboard focus when you click into the add-task field.
final class NotchPanel: NSPanel {
    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// AppKit nudges windows below the menu bar; this one belongs on top of it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Owns the panel and decides when the notch opens and closes.
///
/// While closed the panel ignores the mouse entirely, so the menu bar beneath it keeps working.
/// Pointer position comes from event monitors instead: rest on the notch and it opens; leave the
/// open shape and it closes, unless you're typing a task. A dropped-down banner takes the pointer
/// only while the pointer is over it, so its buttons work and the screen around it stays usable.
final class NotchController {
    private let model: NotchModel
    private var metrics = NotchMetrics.current()
    private var panel: NotchPanel?
    private var host: NSHostingView<NotchRootView>?
    private var monitors: [Any] = []
    private var pendingOpen: Task<Void, Never>?
    private var pendingClose: Task<Void, Never>?

    private static let openDelay: Duration = .milliseconds(70)
    private static let closeDelay: Duration = .milliseconds(260)
    private static let closeSlack: CGFloat = 18

    init(model: NotchModel) {
        self.model = model
    }

    func show() {
        let panel = NotchPanel(frame: metrics.windowFrame)
        let host = NSHostingView(rootView: NotchRootView(model: model, metrics: metrics))
        host.frame = CGRect(origin: .zero, size: metrics.windowFrame.size)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        panel.setFrame(metrics.windowFrame, display: true)
        panel.orderFrontRegardless()

        self.panel = panel
        self.host = host
        model.expandNotch = { [weak self] in self?.setExpanded(true) }
        installMonitors()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }

        if UserDefaults.standard.bool(forKey: "startExpanded") {
            setExpanded(true)
        }
    }

    func setExpanded(_ expanded: Bool) {
        pendingOpen?.cancel(); pendingOpen = nil
        pendingClose?.cancel(); pendingClose = nil
        guard model.isExpanded != expanded else { return }

        if expanded {
            model.clearAlertsForExpand()
            model.refreshNow()
        }
        withAnimation(expanded ? Motion.open : Motion.close) { model.isExpanded = expanded }
        panel?.ignoresMouseEvents = !expanded

        if !expanded {
            model.isEditing = false
            giveBackKeyFocus()
        }
    }

    // MARK: Pointer

    private func installMonitors() {
        let mouse: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .rightMouseDown, .leftMouseDragged]

        if let global = NSEvent.addGlobalMonitorForEvents(matching: mouse, handler: { [weak self] event in
            let type = event.type
            MainActor.assumeIsolated { self?.pointerEvent(type, inOurWindow: false) }
        }) {
            monitors.append(global)
        }

        if let local = NSEvent.addLocalMonitorForEvents(matching: mouse.union(.keyDown), handler: { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53, self.model.isExpanded { // Escape
                    self.setExpanded(false)
                    return nil
                }
                return event
            }
            self.pointerEvent(event.type, inOurWindow: true)
            return event
        }) {
            monitors.append(local)
        }
    }

    private func pointerEvent(_ type: NSEvent.EventType, inOurWindow: Bool) {
        let point = NSEvent.mouseLocation

        switch model.presentation {
        case .closed:
            panel?.ignoresMouseEvents = true
            if closedHoverZone.contains(point) {
                // On the notch itself: open.
                model.setWingsRetracted(false)
                scheduleOpen()
            } else {
                pendingOpen?.cancel(); pendingOpen = nil
                // Over a wing: you're reaching for a menu under it, so the wing steps aside.
                model.setWingsRetracted(wingZone.contains(point))
            }
            return
        case .peek:
            // Resting on a banner holds it; it never opens the panel by itself (click it for that).
            let over = metrics.shapeRect(.peek).contains(point)
            panel?.ignoresMouseEvents = !over
            model.setPeekHovered(over)
            return
        case .open:
            break
        }

        let shape = metrics.shapeRect(model.presentation)
        let isClick = type == .leftMouseDown || type == .rightMouseDown

        // A click anywhere outside the open shape closes it at once, typing or not.
        if isClick && !shape.contains(point) {
            setExpanded(false)
            return
        }

        if shape.insetBy(dx: -Self.closeSlack, dy: -Self.closeSlack).contains(point) {
            pendingClose?.cancel(); pendingClose = nil
        } else if !model.isEditing {
            scheduleClose()
        }
    }

    /// Only the notch itself opens the panel. The wings sit over the menu bar, where your pointer
    /// goes for app menus, so resting there must never open anything.
    private var closedHoverZone: CGRect {
        metrics.shapeRect(.closed(wings: false)).insetBy(dx: -4, dy: 0)
    }

    /// Where the wings are (or would be), with a little room around them.
    private var wingZone: CGRect {
        guard model.showsWings else { return .null }
        return metrics.shapeRect(.closed(wings: true)).insetBy(dx: -8, dy: 0)
    }

    private func scheduleOpen() {
        guard pendingOpen == nil else { return }
        pendingOpen = Task { [weak self] in
            try? await Task.sleep(for: Self.openDelay)
            guard let self, !Task.isCancelled else { return }
            self.pendingOpen = nil
            // Only open if the pointer is still resting on the notch, and no banner dropped meanwhile.
            if case .closed = self.model.presentation, self.closedHoverZone.contains(NSEvent.mouseLocation) {
                self.setExpanded(true)
            }
        }
    }

    private func scheduleClose() {
        guard pendingClose == nil else { return }
        pendingClose = Task { [weak self] in
            try? await Task.sleep(for: Self.closeDelay)
            guard let self, !Task.isCancelled else { return }
            self.pendingClose = nil
            self.setExpanded(false)
        }
    }

    // MARK: Focus and screens

    /// If the add-task field took keyboard focus, hand it back to the app you were in.
    private func giveBackKeyFocus() {
        guard let panel, panel.isKeyWindow else { return }
        panel.orderOut(nil)
        panel.orderFrontRegardless()
    }

    private func screensChanged() {
        let updated = NotchMetrics.current()
        guard updated != metrics else { return }
        metrics = updated
        panel?.setFrame(updated.windowFrame, display: true)
        host?.rootView = NotchRootView(model: model, metrics: updated)
    }
}
