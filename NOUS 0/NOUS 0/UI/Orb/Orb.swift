import SwiftUI

/// Central interactive hub. Emil-style Beacon wrapped in a physics shell so the
/// orb feels like an object with weight instead of a static glyph.
///
/// Physics layer (visual only — does not consume RootView gestures):
///   - Touch-down: spring-squash to 0.94 + 1.08/0.92 asymmetry (press recoil).
///   - Drag: body follows finger w/ rubber-band resistance (0.45×). A small
///     3D tilt is derived from translation so the ring parallaxes.
///   - Release: body springs home (response: 0.55, damping: 0.58 → subtle
///     overshoot so the mass reads). Squash unwinds on a stiffer spring so
///     visual recoil lands before positional settle.
///
/// These run as a `simultaneousGesture` w/ `minimumDistance: 0`, so RootView's
/// existing tap / long-press-voice / swipe gestures still fire unchanged — the
/// physics shell only observes.
struct Orb: View {
    let mode: OrbMode
    var touchPoint: CGPoint = CGPoint(x: 0.5, y: 0.5)   // reserved (legacy callers)

    // Physics state.
    @State private var pressed = false
    @State private var dragOffset: CGSize = .zero

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        physicsLayer
            .simultaneousGesture(physicsGesture)
    }

    // Extracted to help SwiftUI's type-checker — the chained transforms +
    // two animations exceeded the inference budget when inlined.
    private var physicsLayer: some View {
        // Pill press feel: pinch width slightly, compensate height.
        // Horizontal objects resist vertical squash — they compress along their
        // long axis, like pressing a stick of gum.
        let squashX: CGFloat = pressed ? 0.96 : 1.0
        let squashY: CGFloat = pressed ? 1.03 : 1.0
        let dip:     CGFloat = pressed ? 0.97 : 1.0
        let tiltX:   Double  = Double(-dragOffset.height) * 0.08
        let tiltY:   Double  = Double(dragOffset.width)   * 0.08

        let pressAnim: Animation = reduceMotion
            ? .linear(duration: 0.01)
            : .spring(response: 0.22, dampingFraction: 0.58)
        let dragAnim: Animation = reduceMotion
            ? .linear(duration: 0.01)
            : .interactiveSpring(response: 0.28,
                                 dampingFraction: 0.70,
                                 blendDuration: 0.20)

        return OrbBeacon(mode: mode)
            .scaleEffect(x: squashX, y: squashY, anchor: .center)
            .scaleEffect(dip)
            .offset(dragOffset)
            .rotation3DEffect(.degrees(tiltX),
                              axis: (x: 1, y: 0, z: 0), perspective: 0.6)
            .rotation3DEffect(.degrees(tiltY),
                              axis: (x: 0, y: 1, z: 0), perspective: 0.6)
            .animation(pressAnim, value: pressed)
            .animation(dragAnim,  value: dragOffset)
    }

    // MARK: - Physics gesture

    private var physicsGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { g in
                if !pressed { pressed = true }
                // Rubber-band resistance: linear up to ~40pt, then logarithmic
                // so the body feels "pulled against a tether" past a threshold.
                let t = g.translation
                let rubberBand: (CGFloat) -> CGFloat = { v in
                    let a = abs(v), sign: CGFloat = v < 0 ? -1 : 1
                    if a < 40 { return v * 0.45 }
                    let extra = 40 + (log2(a - 39) * 6)     // tail damping
                    return sign * extra * 0.45
                }
                dragOffset = CGSize(
                    width:  rubberBand(t.width),
                    height: rubberBand(t.height)
                )
            }
            .onEnded { _ in
                pressed = false
                // Home-spring has lower damping than the press recoil so you
                // can see the weight settle — but short response so it doesn't
                // block further gestures.
                withAnimation(
                    reduceMotion ? .linear(duration: 0.01)
                                 : .spring(response: 0.55, dampingFraction: 0.58)
                ) {
                    dragOffset = .zero
                }
            }
    }
}
