import SwiftUI

/// Inline TextField with autocomplete dropdown. Used in AtomDetail to add a tag.
/// Suggestions = vault-wide tags by frequency, prefix-filtered, excluding already-attached.
struct AddTagField: View {
    let attached: Set<String>
    let suggestions: [(tag: String, count: Int)]
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    @State private var buffer: String = ""
    @FocusState private var focus: Bool

    private var filtered: [String] {
        let q = TagNormalizer.normalizeOne(buffer)
        let limit = 6
        if q.isEmpty {
            return suggestions
                .filter { !attached.contains($0.tag) }
                .prefix(limit)
                .map(\.tag)
        }
        return suggestions
            .lazy
            .filter { !attached.contains($0.tag) && $0.tag.contains(q) }
            .prefix(limit)
            .map(\.tag)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NSpace.xs) {
            HStack(spacing: NSpace.xs) {
                Text("//")
                    .font(NFont.mono(11))
                    .foregroundStyle(NSColorToken.textGhost)
                TextField("", text: $buffer,
                          prompt: Text("lowercase, hyphens-ok")
                            .foregroundStyle(NSColorToken.textGhost))
                    .font(NFont.mono(11))
                    .foregroundStyle(NSColorToken.textPrimary)
                    .focused($focus)
                    .submitLabel(.done)
                    #if os(iOS) || os(visionOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled(true)
                    .onSubmit { commit() }
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .regular))
                        .foregroundStyle(NSColorToken.textGhost)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, NSpace.sm)
            .padding(.vertical, 4)
            .background(NSColorToken.inkRaised)
            .overlay(
                Rectangle().stroke(NSColorToken.textGhost.opacity(0.4), lineWidth: 0.5)
            )
            if !filtered.isEmpty {
                suggestionsRow
            }
        }
        .task { focus = true }
    }

    private var suggestionsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: NSpace.sm) {
                ForEach(filtered, id: \.self) { tag in
                    Button {
                        onCommit(tag)
                    } label: {
                        Text(tag)
                            .font(NFont.mono(10))
                            .foregroundStyle(NSColorToken.textSecondary)
                            .padding(.horizontal, NSpace.sm)
                            .padding(.vertical, 3)
                            .background(NSColorToken.inkPaper)
                            .overlay(Rectangle().stroke(NSColorToken.textGhost.opacity(0.3), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func commit() {
        let normalized = TagNormalizer.normalizeOne(buffer)
        guard !normalized.isEmpty else { onCancel(); return }
        onCommit(normalized)
    }
}
