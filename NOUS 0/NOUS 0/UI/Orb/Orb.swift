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
    /// Ambient status: ≥1 atom refining in the background. When true AND the orb
    /// is idle, a faint phosphor breath signals "work is happening" without
    /// pulling the orb out of its capture-input role.
    var ambientRefining: Bool = false

    // Physics state.
    @State private var pressed = false
    @State private var dragOffset: CGSize = .zero

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Heartbeat only reads while idle — any active mode owns the orb's meaning.
    private var heartbeatActive: Bool { ambientRefining && mode == .idle }

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
            .background(heartbeatGlow)
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

    // MARK: - Background-refine heartbeat

    /// A soft cyan halo behind the pill, pulsing on `.nBreath` while atoms
    /// refine in the background. Lives behind OrbBeacon so it reads as "the
    /// object is alive / thinking" without altering the pill's own chrome.
    /// Reduce-motion: a single static dim halo (no pulse). Off entirely when
    /// not idle, so active modes (voice / writing / refining) stay unmodified.
    @ViewBuilder
    private var heartbeatGlow: some View {
        let tint = NSColorToken.Phos.cyan
        if heartbeatActive {
            if reduceMotion {
                Capsule()
                    .fill(tint.opacity(0.10))
                    .blur(radius: 12)
                    .allowsHitTesting(false)
            } else {
                HeartbeatHalo(tint: tint)
            }
        }
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

// MARK: - Heartbeat halo

/// Faint phosphor halo that breathes on `.nBreath` (4.2s) while background
/// refine work is in flight. Core Animation owns the loop via
/// `.repeatForever` — no timer, no task, near-zero main-thread cost (mirrors
/// OrbBeacon's `BreathDot`). Opacity + scale both ease so the glow feels like
/// a slow inhale rather than a blink.
private struct HeartbeatHalo: View {
    let tint: Color
    @State private var inhale = false

    var body: some View {
        Capsule()
            .fill(tint.opacity(inhale ? 0.22 : 0.06))
            .blur(radius: 14)
            .scaleEffect(inhale ? 1.06 : 0.98)
            .allowsHitTesting(false)
            .animation(.nBreath.repeatForever(autoreverses: true), value: inhale)
            .onAppear { inhale = true }
    }
}
