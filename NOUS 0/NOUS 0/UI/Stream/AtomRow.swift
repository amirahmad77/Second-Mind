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
            dot.padding(.top, 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(atom.oneLiner)
                    .nDynamicBody(16)
                    .foregroundStyle(NSColorToken.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .contentTransition(.opacity)
                    .animation(.timingCurve(0.23, 1.0, 0.32, 1.0, duration: 0.38), value: atom.displayContent)
                HStack(spacing: NSpace.xs) {
                    Text(metaLine)
                        .font(NFont.mono(11))
                        .foregroundStyle(NSColorToken.textTertiary)
                        .monospacedDigit()
                    if inboundCount > 0 {
                        Text("· ↩\(inboundCount)")
                            .font(NFont.mono(11))
                            .foregroundStyle(NSColorToken.Phos.cyan.opacity(0.75))
                            .monospacedDigit()
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, NSpace.xs)
        .contentShape(Rectangle())
        .polaroidShimmer(isRefining: atom.isRefining, phosphor: atom.type.phosphor)
        .onTapGesture { onTap() }
        .scaleEffect(isSelected ? 1.02 : 1.0)
        .animation(.nPress, value: isSelected)
    }

    @ViewBuilder private var dot: some View {
        let dotView = AtomDot(type: atom.type)
            .scaleEffect(dotBloom)
        Group {
            if let ns = morphNS {
                dotView
                    .matchedGeometryEffect(id: "dot-\(atom.id)", in: ns, properties: .frame, isSource: true)
            } else {
                dotView
            }
        }
        .onChange(of: atom.type) { _, _ in
            // Spring bloom: scale out to 1.8 then settle back to 1.0
            withAnimation(.spring(response: 0.25, dampingFraction: 0.45)) { dotBloom = 1.8 }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                withAnimation(.spring(response: 0.5, dampingFraction: 0.65)) { dotBloom = 1.0 }
            }
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
