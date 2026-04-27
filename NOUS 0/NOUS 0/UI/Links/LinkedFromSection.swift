import SwiftUI

/// Inbound-references surface. Shows atoms that have linked TO this atom.
/// Sits below the "semantically close" related strip in AtomDetail.
struct LinkedFromSection: View {
    let inbound: [AtomSnapshot]
    let onPickAtom: (AtomSnapshot) -> Void

    var body: some View {
        if inbound.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: NSpace.sm) {
                Divider()
                    .frame(height: 0.5)
                    .overlay(NSColorToken.textGhost.opacity(0.25))
                Text(label)
                    .font(NFont.mono(10))
                    .foregroundStyle(NSColorToken.textTertiary)
                    .padding(.horizontal, NSpace.xl)
                    .padding(.top, NSpace.md)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: NSpace.md) {
                        ForEach(inbound) { atom in
                            card(atom)
                        }
                    }
                    .padding(.horizontal, NSpace.xl)
                    .padding(.bottom, NSpace.lg)
                }
            }
            .background(NSColorToken.inkPaper.opacity(0.55))
        }
    }

    private var label: String {
        let n = inbound.count
        return "// linked from · \(n) atom\(n == 1 ? "" : "s")"
    }

    private func card(_ atom: AtomSnapshot) -> some View {
        Button(action: { onPickAtom(atom) }) {
            VStack(alignment: .leading, spacing: NSpace.xs) {
                HStack(spacing: NSpace.xs) {
                    AtomDot(type: atom.type, size: 6)
                    Text(atom.type.label)
                        .font(NFont.mono(9))
                        .foregroundStyle(NSColorToken.textTertiary)
                        .textCase(.uppercase)
                        .tracking(0.10)
                }
                Text(atom.oneLiner)
                    .font(NFont.body(13))
                    .foregroundStyle(NSColorToken.textSecondary)
                    .lineLimit(4)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 200, alignment: .topLeading)
            .padding(NSpace.md)
            .background(NSColorToken.inkRaised)
            .overlay(Rectangle().stroke(NSColorToken.textGhost.opacity(0.25), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }
}
