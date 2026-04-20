import SwiftUI

/// Refining-state indicator: a soft chromatic sweep glides across the row,
/// like a photograph slowly developing in a bath. Active only when `isRefining`,
/// silent otherwise. Respects Reduce Motion (renders a static gentle bias instead).
struct PolaroidShimmer: ViewModifier {
    let isRefining: Bool
    let phosphor: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .leading) {
                if isRefining {
                    if reduceMotion {
                        staticBias
                    } else {
                        sweep
                    }
                }
            }
    }

    /// Animated sweep: a soft diagonal highlight band travels left → right,
    /// tinted with the atom's phosphor. ~2.6s loop, very low alpha so it
    /// reads as ambient development, not a UI spinner.
    private var sweep: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let phase = (t.truncatingRemainder(dividingBy: 2.6)) / 2.6 // 0..1
            GeometryReader { geo in
                let bandW = geo.size.width * 0.45
                let xPos = -bandW + (geo.size.width + bandW * 1.5) * CGFloat(phase)
                LinearGradient(
                    colors: [
                        .clear,
                        phosphor.opacity(0.22),
                        .white.opacity(0.14),
                        phosphor.opacity(0.22),
                        .clear
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: bandW, height: geo.size.height)
                .offset(x: xPos)
                .blendMode(.plusLighter)
                .allowsHitTesting(false)
            }
            .clipped()
            .compositingGroup()
        }
    }

    private var staticBias: some View {
        LinearGradient(
            colors: [phosphor.opacity(0.06), .clear],
            startPoint: .leading,
            endPoint: .trailing
        )
        .blendMode(.plusLighter)
        .allowsHitTesting(false)
    }
}

extension View {
    func polaroidShimmer(isRefining: Bool, phosphor: Color) -> some View {
        modifier(PolaroidShimmer(isRefining: isRefining, phosphor: phosphor))
    }
}
