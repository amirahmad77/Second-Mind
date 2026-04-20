import SwiftUI

struct TextCaptureSheet: View {
    let store: AtomStore
    let onDismiss: () -> Void

    @State private var buffer: String = ""
    @FocusState private var focus: Bool

    var body: some View {
        ZStack {
            NSColorToken.inkScrim.ignoresSafeArea()
                .onTapGesture { dismiss(save: false) }

            VStack(alignment: .leading, spacing: NSpace.md) {
                Spacer()
                VStack(alignment: .leading, spacing: NSpace.sm) {
                    HStack {
                        Text("// capture")
                            .font(NFont.mono(11))
                            .foregroundStyle(NSColorToken.textTertiary)
                        Spacer()
                        Button("save") { dismiss(save: true) }
                            .font(NFont.mono(12))
                            .foregroundStyle(buffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                             ? NSColorToken.textGhost : NSColorToken.Phos.cyan)
                            .disabled(buffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    TextEditor(text: $buffer)
                        .font(NFont.body(18))
                        .foregroundStyle(NSColorToken.textPrimary)
                        .scrollContentBackground(.hidden)
                        .focused($focus)
                        .frame(minHeight: 120, maxHeight: 280)
                }
                .padding(NSpace.xl)
                .background(NSColorToken.inkRaised)
            }
        }
        .task { focus = true }
        .onSubmit { dismiss(save: true) }
    }

    private func dismiss(save: Bool) {
        let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if save && !trimmed.isEmpty {
            _ = store.capture(raw: trimmed, type: classify(trimmed))
            Haptics.shared.saveConfirm()
        }
        onDismiss()
    }

    /// Light heuristic classifier — cheap + overridable via Gemini later.
    private func classify(_ s: String) -> AtomType {
        let lc = s.lowercased()
        if lc.hasPrefix("todo") || lc.hasPrefix("- [ ]") || lc.contains("need to ") { return .task }
        if lc.contains("?") { return .question }
        if lc.contains("meeting") || lc.contains("mtg") { return .meeting }
        if lc.hasPrefix("decision") || lc.contains("decided") { return .decision }
        return .thought
    }
}
