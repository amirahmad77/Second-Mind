import SwiftUI

/// Auto-suggested links surface. Sits between body and tags in AtomDetail.
/// Tap chip = confirm + brief pulse + emit linked event + remove from strip.
/// Long-press chip = dismiss without linking.
struct AlsoSeeStrip: View {
    let atomID: UUID
    let suggestions: [AtomStore.LinkSuggestion]
    let store: AtomStore

    @State private var pulsing: Set<UUID> = []

    var body: some View {
        if suggestions.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: NSpace.xs) {
                Text("// also see")
                    .font(NFont.mono(10))
                    .foregroundStyle(NSColorToken.textTertiary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: NSpace.sm) {
                        ForEach(suggestions) { sug in
                            chip(for: sug)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func chip(for sug: AtomStore.LinkSuggestion) -> some View {
        if let atom = store.atoms[sug.target] {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: NSpace.xs) {
                    AtomDot(type: atom.type, size: 5)
                    Text(atom.oneLiner)
                        .font(NFont.body(13))
                        .foregroundStyle(NSColorToken.textPrimary)
                        .lineLimit(1)
                }
                if !sug.reason.isEmpty {
                    Text(sug.reason)
                        .font(NFont.mono(9))
                        .foregroundStyle(NSColorToken.textGhost)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: 240, alignment: .leading)
            .padding(.horizontal, NSpace.sm)
            .padding(.vertical, 6)
            .background(
                NSColorToken.inkRaised
                    .overlay(
                        // brief cyan flash on confirm
                        NSColorToken.Phos.cyan
                            .opacity(pulsing.contains(sug.target) ? 0.30 : 0.0)
                    )
            )
            .overlay(
                Rectangle().stroke(
                    NSColorToken.Phos.amber.opacity(0.4),
                    lineWidth: 0.5
                )
            )
            .contentShape(Rectangle())
            .onTapGesture {
                confirm(target: sug.target)
            }
            .onLongPressGesture(minimumDuration: 0.35) {
                dismiss(target: sug.target)
            }
        }
    }

    private func confirm(target: UUID) {
        Haptics.shared.softTick()
        withAnimation(.nEaseOutQuint) { pulsing.insert(target) }
        // After the pulse, persist the link + remove from strip.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 280_000_000)
            store.confirmSuggestion(for: atomID, target: target)
            pulsing.remove(target)
        }
    }

    private func dismiss(target: UUID) {
        Haptics.shared.heavyThud()
        withAnimation(.nEaseOutQuint) {
            store.dismissSuggestion(for: atomID, target: target)
        }
    }
}
