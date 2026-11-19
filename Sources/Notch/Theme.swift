import AppKit
import SwiftUI

/// The notch is black because the camera housing is black: the panel has to read as the
/// hardware growing, not as a window. Everything else stays quiet: soft white ink on one
/// opacity ladder, one active color, and orange only for focus.
enum Ink {
    static let surface = Color.black
    static let primary = Color(red: 0.988, green: 0.988, blue: 0.992) // #fcfcfd
    static let secondary = primary.opacity(0.64)
    static let tertiary = primary.opacity(0.42)
    static let hairline = primary.opacity(0.10)
    /// The active color: whatever is happening now. A light blue, so it holds contrast on black.
    static let accent = Color(red: 0.42, green: 0.55, blue: 1.0)
    /// Focus mode only: a warm orange (#D97757). Focus should feel more intense and serious than
    /// anything else in the notch, so it gets its own color and nothing else uses it.
    static let focus = Color(red: 0.851, green: 0.467, blue: 0.341)
    /// Overdue only. A clear red, kept well apart from the focus orange so the two never read alike;
    /// red is also how Calendar and Reminders already say "late".
    static let late = Color(red: 1.0, green: 0.27, blue: 0.23)
}

/// Motion for the notch. Opening and closing should feel fluid, like the Dynamic Island, so the
/// notch uses springs: they carry their velocity when interrupted (hover in, then out mid-open),
/// which is what makes them read as fluid. Everything else in the app eases out with no overshoot.
/// Opening settles with a slight give; closing never overshoots.
enum Motion {
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    static var open: Animation {
        reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.42, bounce: 0.16)
    }

    static var close: Animation {
        reduceMotion ? .easeOut(duration: 0.12) : .spring(duration: 0.3, bounce: 0)
    }

    /// Wings growing or shrinking beside the camera.
    static var morph: Animation {
        reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.38, bounce: 0.1)
    }

    /// Content fading in once the shape has started to open.
    static var contentIn: Animation {
        .timingCurve(0, 0, 0.2, 1, duration: 0.28).delay(reduceMotion ? 0 : 0.08)
    }

    static var contentOut: Animation {
        .timingCurve(0.4, 0, 1, 1, duration: 0.12)
    }
}
