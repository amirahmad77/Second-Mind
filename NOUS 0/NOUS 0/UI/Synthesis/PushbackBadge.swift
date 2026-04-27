import SwiftUI

/// Ambient badge floating above the Orb when pushback items exist.
/// Soft violet pulse — never alarming. Tap → opens PushbackSheet.
struct PushbackBadge: View {
    let count: Int
    let onTap: () -> Void

    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: NSpace.xs) {
                Circle()
                    .fill(NSColorToken.Phos.violet)
                    .frame(width: 5, height: 5)
                    .shadow(color: NSColorToken.Phos.violet.opacity(0.7), radius: 4)
                    .scaleEffect(pulse && !reduceMotion ? 1.4 : 1.0)
                    .opacity(pulse && !reduceMotion ? 0.6 : 1.0)
                Text("\(count)")
                    .font(NFont.mono(10))
                    .foregroundStyle(NSColorToken.textSecondary)
                    .monospacedDigit()
                Text("· consider")
                    .font(NFont.mono(10))
                    .foregroundStyle(NSColorToken.textTertiary)
            }
            .padding(.horizontal, NSpace.sm)
            .padding(.vertical, 5)
            .background(NSColorToken.inkRaised.opacity(0.85))
            .overlay(Rectangle().stroke(NSColorToken.Phos.violet.opacity(0.35), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}
