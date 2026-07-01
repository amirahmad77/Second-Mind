import SwiftUI

struct DeleteUndoToast: View {
    let manager: DeleteUndoManager
    let store: AtomStore

    var body: some View {
        HStack(spacing: NSpace.md) {
            Text("atom deleted")
                .font(NFont.mono(12))
                .foregroundStyle(NSColorToken.textGhost)
            Text("·")
                .font(NFont.mono(12))
                .foregroundStyle(NSColorToken.textGhost.opacity(0.4))
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                    manager.undo(store: store)
                }
            } label: {
                Text("undo")
                    .font(NFont.mono(12).weight(.medium))
                    .foregroundStyle(NSColorToken.Phos.amber)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Undo delete")
            .accessibilityHint("Restores the deleted atom")
        }
        .padding(.horizontal, NSpace.lg)
        .padding(.vertical, NSpace.xs)
        .background(
            Capsule()
                .fill(NSColorToken.inkRaised)
                .overlay(
                    Capsule()
                        .stroke(NSColorToken.textGhost.opacity(0.14), lineWidth: 0.5)
                )
        )
        .shadow(color: NSColorToken.inkVoid.opacity(0.85), radius: 20, y: 6)
    }
}
