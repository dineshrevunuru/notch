import NotchCore
import SwiftUI

/// One black shape that grows and shrinks, with three layers inside it:
/// - the open panel's content, always built and revealed as the shape grows (nothing is created
///   at the moment it opens, so the first frames don't stutter);
/// - a dropped-down banner;
/// - the glance wings, which stay exactly in place from closed to open, so what you saw beside the
///   camera is still there, in the band, after the notch opens.
struct NotchRootView: View {
    let model: NotchModel
    let metrics: NotchMetrics

    var body: some View {
        let presentation = model.presentation
        let size = metrics.shapeSize(presentation)
        let radii = NotchMetrics.radii(presentation)
        let shape = NotchShape(topRadius: radii.top, bottomRadius: radii.bottom)
        let isOpen: Bool = if case .open = presentation { true } else { false }
        let lifted = isOpen || presentation == .peek
        let showsWings: Bool = {
            switch presentation {
            case .open: true
            case .closed(let wings): wings
            case .peek: false
            }
        }()

        ZStack(alignment: .top) {
            shape
                .fill(Ink.surface)
                .frame(width: size.width, height: size.height)
                .shadow(color: .black.opacity(lifted ? 0.3 : 0), radius: 16, y: 8)

            ZStack(alignment: .top) {
                ExpandedView(model: model, metrics: metrics)
                    .opacity(isOpen ? 1 : 0)
                    .scaleEffect(isOpen ? 1 : 0.96, anchor: .top)
                    .allowsHitTesting(isOpen)
                    .accessibilityHidden(!isOpen)

                if presentation == .peek, let alert = model.currentAlert {
                    PeekView(alert: alert, model: model, metrics: metrics)
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                }

                WingsView(model: model, metrics: metrics, isOpen: isOpen)
                    .opacity(showsWings ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .frame(width: size.width, height: size.height, alignment: .top)
            .clipShape(shape)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(Motion.morph, value: model.showsWings)
        .animation(Motion.morph, value: model.openHeight)
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
    }
}
