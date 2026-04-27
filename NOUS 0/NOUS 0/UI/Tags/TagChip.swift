import SwiftUI

/// Single tag chip. The tag IS the word — chrome is air.
/// Mono lowercase, hairline phosphor underline. No pill, no fill.
struct TagChip: View {
    let value: String
    /// Phosphor color (atom's type color). Underline tints to this.
    var phosphor: Color = NSColorToken.Phos.cyan
    /// Visual scale: full (detail) or compact (search hits).
    var compact: Bool = false

    var body: some View {
        Text(value)
            .font(NFont.mono(compact ? 9 : 11))
            .foregroundStyle(NSColorToken.textSecondary)
            .tracking(0.06)
            .padding(.horizontal, 2)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(phosphor.opacity(0.55))
                    .frame(height: compact ? 0.5 : 0.75)
            }
            .fixedSize()
    }
}
