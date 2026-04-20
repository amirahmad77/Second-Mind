import SwiftUI

struct AtomRow: View {
    let atom: AtomSnapshot
    let isSelected: Bool
    var morphNS: Namespace.ID? = nil
    let onTap: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: NSpace.md) {
            dot.padding(.top, 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(atom.oneLiner)
                    .font(NFont.body(16))
                    .foregroundStyle(NSColorToken.textPrimary)
                    .lineLimit(3)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                Text(metaLine)
                    .font(NFont.mono(11))
                    .foregroundStyle(NSColorToken.textTertiary)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, NSpace.xs)
        .contentShape(Rectangle())
        .polaroidShimmer(isRefining: atom.isRefining, phosphor: atom.type.phosphor)
        .onTapGesture { onTap() }
        .opacity(atom.isDeleted ? 0.2 : 1.0)
        .scaleEffect(isSelected ? 1.02 : 1.0)
        .animation(.nPress, value: isSelected)
    }

    @ViewBuilder private var dot: some View {
        if let ns = morphNS {
            AtomDot(type: atom.type)
                .matchedGeometryEffect(id: "dot-\(atom.id)", in: ns, properties: .frame, isSource: true)
        } else {
            AtomDot(type: atom.type)
        }
    }

    private var metaLine: String {
        var s = atom.createdAt.formatted(date: .omitted, time: .shortened)
        if atom.type == .meeting { s += " · from meeting" }
        if atom.type == .task, let done = atom.taskDone {
            s += done ? " · done" : " · open"
        }
        return s
    }
}
