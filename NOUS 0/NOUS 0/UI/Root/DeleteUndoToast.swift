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
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, NSpace.lg)
        .padding(.vertical, NSpace.sm)
        .background(
            Capsule()
                .fill(Color(white: 0.10))
                .overlay(
                    Capsule()
                        .stroke(NSColorToken.textGhost.opacity(0.12), lineWidth: 0.5)
                )
        )
        .shadow(color: .black.opacity(0.4), radius: 16, y: 4)
    }
}
