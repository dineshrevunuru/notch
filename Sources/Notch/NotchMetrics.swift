import AppKit

/// The three shapes the notch takes.
enum NotchPresentation: Equatable {
    /// The camera housing, with glance wings beside it when there's something to show.
    case closed(wings: Bool)
    /// A banner dropped down on its own: a reminder, a deadline, a meeting about to start.
    case peek
    /// Opened by hovering: the full panel, as tall as what it holds.
    case open(height: CGFloat)
}

/// Where the notch is and how big each presentation is.
/// "Body" sizes exclude the small outward curves where the shape meets the top edge.
struct NotchMetrics: Equatable {
    /// Screen holding the notch, in global screen coordinates (origin bottom-left).
    let screenFrame: CGRect
    /// The camera housing. On a Mac without one, a menu-bar-height stand-in.
    let notchSize: CGSize
    let notchCenterX: CGFloat
    let hasHardwareNotch: Bool

    static let openWidth: CGFloat = 640
    /// The tallest the open panel gets; the window is sized for this once.
    static let maxOpenHeight: CGFloat = 324
    static let openTopRadius: CGFloat = 14
    /// At least as wide as the closed notch with wings, so a banner only ever grows.
    static let peekBodyWidth: CGFloat = 520
    static let peekContentHeight: CGFloat = 66
    /// Closed: an icon and a short value ("5 PM", "18:24"), so app menus under the wings stay visible.
    static let compactWingWidth: CGFloat = 76
    /// Room around the expanded shape for its shadow.
    static let shadowMargin: CGFloat = 32

    static func current() -> NotchMetrics {
        let notched = NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
        guard let screen = notched ?? NSScreen.main ?? NSScreen.screens.first else {
            return NotchMetrics(screenFrame: .zero, notchSize: CGSize(width: 200, height: 32), notchCenterX: 0, hasHardwareNotch: false)
        }
        let frame = screen.frame

        if notched != nil, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let width = right.minX - left.maxX
            return NotchMetrics(
                screenFrame: frame,
                notchSize: CGSize(width: width, height: screen.safeAreaInsets.top),
                notchCenterX: frame.minX + left.maxX + width / 2,
                hasHardwareNotch: true
            )
        }

        let menuBarHeight = max(24, frame.maxY - screen.visibleFrame.maxY)
        return NotchMetrics(
            screenFrame: frame,
            notchSize: CGSize(width: 200, height: menuBarHeight),
            notchCenterX: frame.midX,
            hasHardwareNotch: false
        )
    }

    // MARK: Shape sizes

    func body(_ presentation: NotchPresentation) -> CGSize {
        switch presentation {
        case .closed(let wings):
            CGSize(width: notchSize.width + (wings ? Self.compactWingWidth * 2 : 0), height: notchSize.height)
        case .peek:
            CGSize(width: Self.peekBodyWidth, height: notchSize.height + Self.peekContentHeight)
        case .open(let height):
            CGSize(width: Self.openWidth, height: min(height, Self.maxOpenHeight))
        }
    }

    static func radii(_ presentation: NotchPresentation) -> (top: CGFloat, bottom: CGFloat) {
        switch presentation {
        case .closed: (4, 10)
        case .peek: (10, 22)
        case .open: (openTopRadius, 28)
        }
    }

    /// The shape's full frame size, including the top curves on both sides.
    func shapeSize(_ presentation: NotchPresentation) -> CGSize {
        let body = body(presentation)
        return CGSize(width: body.width + Self.radii(presentation).top * 2, height: body.height)
    }

    // MARK: Screen rects

    /// The panel is sized once, to fit the expanded shape plus its shadow, and pinned to the top edge.
    var windowFrame: CGRect {
        let shape = shapeSize(.open(height: Self.maxOpenHeight))
        let width = shape.width + Self.shadowMargin * 2
        let height = shape.height + Self.shadowMargin
        return CGRect(x: notchCenterX - width / 2, y: screenFrame.maxY - height, width: width, height: height)
    }

    /// The shape's rect in screen coordinates — what the pointer is tested against.
    func shapeRect(_ presentation: NotchPresentation) -> CGRect {
        let size = shapeSize(presentation)
        // Reach slightly above the top edge: the pointer pinned against the edge reports y == maxY.
        return CGRect(x: notchCenterX - size.width / 2, y: screenFrame.maxY - size.height, width: size.width, height: size.height + 2)
    }
}
