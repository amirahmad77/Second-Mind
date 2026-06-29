import SwiftUI

struct AtomRow: View {
    let atom: AtomSnapshot
    let isSelected: Bool
    var morphNS: Namespace.ID? = nil
    var inboundCount: Int = 0
    let onTap: () -> Void

    @State private var dotBloom: CGFloat = 1.0

    var body: some View {
        HStack(alignment: .top, spacing: NSpace.md) {
            dot.padding(.top, 5)

            VStack(alignment: .leading, spacing: NSpace.xs) {
                // Title — 2 lines, full weight
                Text(atom.oneLiner)
                    .nDynamicBody(15)
                    .foregroundStyle(NSColorToken.textPrimary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
                    .animation(.timingCurve(0.23, 1.0, 0.32, 1.0, duration: 0.38), value: atom.displayContent)

                // Meta row — ghost-level, clearly subordinate
                HStack(spacing: NSpace.xs) {
                    Text(atom.createdAt.formatted(date: .omitted, time: .shortened))
                        .font(NFont.mono(10))
                        .foregroundStyle(NSColorToken.textGhostDim)
                        .monospacedDigit()
                    if inboundCount > 0 {
                        Text("· ← \(inboundCount)")
                            .font(NFont.mono(10))
                            .foregroundStyle(atom.type.phosphor.opacity(0.65))
                            .monospacedDigit()
                    }
                    if atom.refineFailed {
                        Text("· // refine failed")
                            .font(NFont.mono(10))
                            .foregroundStyle(NSColorToken.Phos.orange.opacity(0.70))
                    }
                }

                // Tags — flat ghost text, minimal footprint
                if !visibleTags.isEmpty {
                    Text(visibleTags.joined(separator: " · "))
                        .font(NFont.mono(10))
                        .foregroundStyle(NSColorToken.textGhostDim)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, NSpace.md)
        // Selection: phosphor wash + 2pt leading edge bar — the shared selection
        // language with macOS MacAtomRow (treatment unified, density kept roomy).
        .background(
            atom.type.phosphor
                .opacity(isSelected ? 0.12 : 0)
                .animation(.nEaseOutQuint, value: isSelected)
        )
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(atom.type.phosphor.opacity(isSelected ? 0.85 : 0))
                .frame(width: 2)
                .animation(.nEaseOutQuint, value: isSelected)
        }
        .contentShape(Rectangle())
        .polaroidShimmer(isRefining: atom.isRefining, phosphor: atom.type.phosphor)
        .onTapGesture { onTap() }
        .animation(.nPress, value: isSelected)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(rowAccessibilityLabel)
        .accessibilityHint("Double-tap to open")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Helpers

    private var rowAccessibilityLabel: String {
        var parts: [String] = [atom.type.label, atom.oneLiner]
        if inboundCount > 0 { parts.append("\(inboundCount) link\(inboundCount == 1 ? "" : "s")") }
        if atom.isRefining { parts.append("refining") }
        if atom.refineFailed { parts.append("refine failed") }
        return parts.joined(separator: ", ")
    }

    private var visibleTags: [String] {
        Array(atom.tags.prefix(3).map(\.value))
    }

    @ViewBuilder private var dot: some View {
        // dotBloom handles the transient type-change burst.
        // isSelected adds a persistent glow: scale 1.25 + intensified shadow.
        // Both stack multiplicatively so the bloom still fires correctly when selected.
        let effectiveScale = dotBloom * (isSelected ? 1.25 : 1.0)
        let dotView = AtomDot(type: atom.type)
            .scaleEffect(effectiveScale)
            // On/off chroma: selected dot at full color, unselected dimmed.
            .opacity(isSelected ? 1.0 : NSColorToken.Phos.dimOpacity)
            // Selection halo: phosphor activeGlow ring radiates when selected.
            .shadow(color: isSelected ? atom.type.phosphor.opacity(0.55) : .clear,
                    radius: NSColorToken.Phos.activeGlow, x: 0, y: 0)
            .animation(.nEaseOutQuint, value: isSelected)
        Group {
            if let ns = morphNS {
                dotView.matchedGeometryEffect(id: "dot-\(atom.id)", in: ns,
                                              properties: .frame, isSource: true)
            } else {
                dotView
            }
        }
        .onChange(of: atom.type) { _, _ in
            withAnimation(.spring(response: 0.25, dampingFraction: 0.45)) { dotBloom = 1.8 }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                withAnimation(.spring(response: 0.5, dampingFraction: 0.65)) { dotBloom = 1.0 }
            }
        }
    }
}
