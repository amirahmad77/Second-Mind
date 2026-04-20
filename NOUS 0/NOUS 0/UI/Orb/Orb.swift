import SwiftUI

struct Orb: View {
    let mode: OrbMode
    var touchPoint: CGPoint = CGPoint(x: 0.5, y: 0.5)   // normalized 0..1

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathe = false

    var body: some View {
        let v = OrbVisual.from(mode)
        ZStack {
            // Diffused halo
            Circle()
                .fill(RadialGradient(
                    colors: [v.haloColor.opacity(v.haloAlpha), .clear],
                    center: .center, startRadius: 0, endRadius: v.haloRadius * 0.55))
                .frame(width: v.haloRadius, height: v.haloRadius)
                .blur(radius: v.haloBlur)
                .allowsHitTesting(false)

            // Liquid body via Metal shader. Reduce Motion → freeze. High-energy modes → 60fps; ambient → 30fps.
            TimelineView(.animation(minimumInterval: shaderInterval(for: mode), paused: reduceMotion)) { ctx in
                let t = reduceMotion ? Float(0)
                    : Float(ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 10_000))
                Circle()
                    .fill(.ultraThinMaterial)
                    .colorEffect(ShaderLibrary.orbLiquid(
                        .float(t),
                        .float(Float(v.amp)),
                        .float2(Float(touchPoint.x), Float(touchPoint.y)),
                        .color(v.phos)
                    ))
                    .frame(width: v.bodySize, height: v.bodySize)
                    .scaleEffect(v.breathe && !reduceMotion ? (breathe ? 1.03 : 0.97) : 1.0)
                    .animation(reduceMotion ? nil : .nBreath.repeatForever(autoreverses: true), value: breathe)
            }

            // Meniscus
            Circle()
                .stroke(LinearGradient(
                    colors: [NSColorToken.textPrimary.opacity(0.18), .clear],
                    startPoint: .top, endPoint: .bottom), lineWidth: 0.5)
                .frame(width: v.bodySize, height: v.bodySize)
                .allowsHitTesting(false)

            if let label = v.label {
                Text(label)
                    .font(NFont.mono(10))
                    .foregroundStyle(NSColorToken.textGhost)
                    .offset(y: v.bodySize * 0.9)
            }
        }
        .compositingGroup()
        .onAppear { breathe = v.breathe }
        .onChange(of: v.breathe) { _, new in breathe = new }
    }

    private func shaderInterval(for mode: OrbMode) -> Double {
        switch mode {
        case .voice, .voiceCancelZone: return 1.0 / 60.0
        case .textActive, .search:     return 1.0 / 45.0
        case .idle, .refining:         return 1.0 / 30.0
        }
    }
}
