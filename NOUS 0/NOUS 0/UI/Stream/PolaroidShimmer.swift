import SwiftUI

/// Phosphor-scan refining indicator.
///
/// A luminous sweep — outer diffuse halo + bright gaussian core — travels
/// left-to-right across the row while the AI processes the atom. The halo
/// bleeds ~22pt past the row's horizontal edges so the glow feels like
/// ambient light, not a boxed UI element.
///
/// Lifecycle: fades in when `isRefining` becomes true, fades out when false.
/// Respects Reduce Motion (static ambient tint instead of motion).
struct PolaroidShimmer: ViewModifier {
    let isRefining: Bool
    let phosphor: Color

    @State private var phase: CGFloat = 0
    @State private var glowOpacity: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { geo in
                    if reduceMotion {
                        if isRefining { staticBias }
                    } else {
                        sweep(rowW: geo.size.width, rowH: geo.size.height)
                    }
                }
                .allowsHitTesting(false)
            }
            .task(id: isRefining) {
                await drive()
            }
    }

    // MARK: – Animation driver

    private func drive() async {
        guard isRefining, !reduceMotion else {
            withAnimation(.easeOut(duration: 0.4)) { glowOpacity = 0 }
            return
        }

        // Fade in
        withAnimation(.easeOut(duration: 0.35)) { glowOpacity = 1 }

        // Sweep loop: 2.8s travel + 1.5s dark pause = unhurried ambient pulse
        while !Task.isCancelled {
            phase = 0                                                    // instant reset (beam is off-screen left)
            withAnimation(.linear(duration: 2.8)) { phase = 1 }         // beam travels to off-screen right
            try? await Task.sleep(for: .seconds(4.3))                   // 2.8 travel + 1.5 gap
            if Task.isCancelled { break }
        }
    }

    // MARK: – Sweep layers

    private func sweep(rowW: CGFloat, rowH: CGFloat) -> some View {
        let bleed: CGFloat  = 22    // horizontal overshoot past row edges
        let beamW: CGFloat  = 80    // core streak width
        // Beam center travels from just-off leading to just-off trailing
        let startX = -(bleed + beamW * 0.5)
        let endX   = rowW + bleed + beamW * 0.5
        let cx     = startX + phase * (endX - startX)

        return ZStack {
            // ── Layer 1: diffuse phosphor cloud ───────────────────────────
            // Wide flat ellipse with heavy blur → spreads past row edges and
            // creates the atmospheric "light behind glass" halo.
            Ellipse()
                .fill(phosphor.opacity(0.26))
                .frame(width: beamW * 2.6, height: rowH * 1.5)
                .blur(radius: 20)

            // ── Layer 2: luminous gaussian core ───────────────────────────
            // Bell-curve gradient + light blur → hot centre, soft shoulder
            Rectangle()
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: .clear,                 location: 0.00),
                            .init(color: phosphor.opacity(0.05), location: 0.08),
                            .init(color: phosphor.opacity(0.22), location: 0.28),
                            .init(color: phosphor.opacity(0.42), location: 0.44),
                            .init(color: .white.opacity(0.24),   location: 0.50),
                            .init(color: phosphor.opacity(0.42), location: 0.56),
                            .init(color: phosphor.opacity(0.22), location: 0.72),
                            .init(color: phosphor.opacity(0.05), location: 0.92),
                            .init(color: .clear,                 location: 1.00),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: beamW, height: rowH)
                .blur(radius: 3)
        }
        // position(x:y:) anchors at the ZStack's centre — matches our cx math
        .position(x: cx, y: rowH * 0.5)
        .opacity(glowOpacity)
        .blendMode(.plusLighter)
    }

    // MARK: – Reduced-motion fallback

    private var staticBias: some View {
        LinearGradient(
            colors: [phosphor.opacity(0.08), .clear],
            startPoint: .leading,
            endPoint: .trailing
        )
        .blendMode(.plusLighter)
    }
}

extension View {
    func polaroidShimmer(isRefining: Bool, phosphor: Color) -> some View {
        modifier(PolaroidShimmer(isRefining: isRefining, phosphor: phosphor))
    }
}
