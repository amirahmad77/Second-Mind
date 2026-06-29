import SwiftUI

/// First-run intro to the `//` model. The interface is intentionally terse —
/// this overlay teaches the surfaces (stream / constellation / entities /
/// synthesize) and the command grammar once, then never again.
///
/// Gate it on `@AppStorage("nous.hasSeenOnboarding")` at the call site and call
/// `onDismiss` to set the flag. Shared by iOS and macOS — no platform branch.
struct OnboardingOverlay: View {
    var onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    private struct Surface: Identifiable {
        let id = UUID()
        let glyph: String
        let name: String
        let blurb: String
        let color: Color
    }

    private var surfaces: [Surface] {
        [
            .init(glyph: "// stream",       name: "stream",       blurb: "Everything you capture, newest first.",        color: NSColorToken.Phos.cyan),
            .init(glyph: "// constellation", name: "constellation", blurb: "Your notes as a linked graph.",                 color: NSColorToken.Phos.violet),
            .init(glyph: "// entities",     name: "entities",     blurb: "People and things, pulled out automatically.",  color: NSColorToken.Phos.green),
            .init(glyph: "// synthesize",   name: "synthesize",   blurb: "Ask across your meetings and notes.",           color: NSColorToken.Phos.amber),
        ]
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(NSColorToken.inkVoid.opacity(0.82))
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            VStack(alignment: .leading, spacing: NSpace.xl) {
                VStack(alignment: .leading, spacing: NSpace.xs) {
                    Text("nous")
                        .font(NFont.dayHeader(34))
                        .foregroundStyle(NSColorToken.textPrimary)
                    Text("// thinking environment")
                        .font(NFont.mono(12))
                        .foregroundStyle(NSColorToken.textGhostDim)
                }

                VStack(alignment: .leading, spacing: NSpace.md) {
                    ForEach(surfaces) { s in
                        HStack(alignment: .firstTextBaseline, spacing: NSpace.md) {
                            Text(s.glyph)
                                .font(NFont.monoSmall(12))
                                .foregroundStyle(s.color)
                                .frame(width: 128, alignment: .leading)
                            Text(s.blurb)
                                .font(NFont.mono(12))
                                .foregroundStyle(NSColorToken.textSecondary)
                        }
                    }
                }

                HStack(spacing: NSpace.xs) {
                    Text("tip")
                        .font(NFont.monoSmall(11))
                        .foregroundStyle(NSColorToken.textGhostDim)
                    Text("⌘N captures a thought from anywhere.")
                        .font(NFont.mono(11))
                        .foregroundStyle(NSColorToken.textTertiary)
                }

                Button(action: dismiss) {
                    Text("// begin")
                        .font(NFont.monoSmall(13))
                        .foregroundStyle(NSColorToken.Phos.cyan)
                        .padding(.horizontal, NSpace.lg)
                        .padding(.vertical, NSpace.sm)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(NSColorToken.Phos.cyan.opacity(0.35), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel("Begin using NOUS")
            }
            .padding(NSpace.xxl)
            .frame(maxWidth: 480, alignment: .leading)
            .background(NSColorToken.inkPaper)
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(NSColorToken.textGhost.opacity(0.18), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .shadow(color: .black.opacity(0.4), radius: 28, y: 12)
            .scaleEffect(appeared || reduceMotion ? 1 : 0.96)
            .opacity(appeared || reduceMotion ? 1 : 0)
        }
        .onAppear {
            withAnimation(reduceMotion ? nil : .nEaseOutQuint) { appeared = true }
        }
        .accessibilityAddTraits(.isModal)
    }

    private func dismiss() {
        withAnimation(reduceMotion ? nil : .nEaseOutQuint) { appeared = false }
        onDismiss()
    }
}
