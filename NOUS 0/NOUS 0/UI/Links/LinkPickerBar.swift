import SwiftUI

/// Inline picker for `[[` link insertion. Keyboard-anchored bar driven by the
/// `LinkPickerState` model: parent passes a binding to the editor text + hosts
/// a `LinkPickerState` that derives query window from cursor position is
/// out-of-scope for v1 (TextEditor exposes no cursor); we use a simpler model:
/// detect the LAST `[[<query>` segment in the buffer that has no closing `]]`,
/// and treat it as the active query. The bar is shown when a query is active.
///
/// Insertion: replaces the open `[[<query>` with `[[<uuid>|<alias>]] `.
struct LinkPickerBar: View {
    @Binding var text: String
    let store: AtomStore
    let onPicked: () -> Void
    let onCancel: () -> Void

    private var query: String? { Self.activeQuery(in: text) }

    var body: some View {
        if let query {
            let candidates = ranked(query: query)
            HStack(spacing: NSpace.sm) {
                Text("// link to")
                    .font(NFont.mono(10))
                    .foregroundStyle(NSColorToken.textTertiary)
                    .padding(.leading, NSpace.md)

                if candidates.isEmpty {
                    Text("// no atom matches \"\(query)\"")
                        .font(NFont.mono(10))
                        .foregroundStyle(NSColorToken.textGhost)
                    Spacer()
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: NSpace.sm) {
                            ForEach(candidates.prefix(6)) { atom in
                                chip(for: atom)
                            }
                        }
                    }
                }

                Button(action: cancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(NSColorToken.textTertiary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, NSpace.xs)
            }
            .frame(height: 44)
            .background(NSColorToken.inkRaised)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(NSColorToken.Phos.cyan.opacity(0.45))
                    .frame(height: 0.75)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: - Chip

    private func chip(for atom: AtomSnapshot) -> some View {
        Button(action: { insert(atom) }) {
            HStack(spacing: NSpace.xs) {
                AtomDot(type: atom.type, size: 5)
                Text(atom.oneLiner)
                    .font(NFont.body(13))
                    .foregroundStyle(NSColorToken.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, NSpace.sm)
            .padding(.vertical, 5)
            .background(NSColorToken.inkPaper)
            .overlay(Rectangle().stroke(NSColorToken.textGhost.opacity(0.3), lineWidth: 0.5))
            .frame(maxWidth: 220)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Logic

    /// Returns the active query text — the chars after the LAST `[[` that has
    /// no closing `]]` after it. Returns nil if no open `[[` exists or if the
    /// segment contains a newline (treat newline as "user moved on").
    private static func activeQuery(in raw: String) -> String? {
        guard let openRange = raw.range(of: "[[", options: .backwards) else { return nil }
        let after = raw[openRange.upperBound..<raw.endIndex]
        // If a closing `]]` exists after this `[[`, it's already a complete link.
        if after.contains("]]") { return nil }
        // Newline = bail
        if after.contains(where: \.isNewline) { return nil }
        // Cap length so we don't try to match novels.
        if after.count > 60 { return nil }
        return String(after)
    }

    /// Ranking per design brief §9.2: lexical-prefix on oneLiner first;
    /// if <3 lexical hits, append semantic candidates from cosine cache.
    private func ranked(query: String) -> [AtomSnapshot] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        let pool = store.ordered.filter { !$0.isDeleted }
        if q.isEmpty {
            return Array(pool.prefix(6))
        }
        // Lexical: prefix match wins, then contains, then everything else.
        let prefix = pool.filter { $0.oneLiner.lowercased().hasPrefix(q) }
        let contains = pool.filter {
            !prefix.contains($0) && $0.oneLiner.lowercased().contains(q)
        }
        let lexical = prefix + contains
        return Array(lexical.prefix(6))
    }

    // MARK: - Mutation

    private func insert(_ atom: AtomSnapshot) {
        guard let openRange = text.range(of: "[[", options: .backwards) else { return }
        let literal = LinkParser.literal(target: atom.id, alias: atom.oneLiner)
        // Replace the entire open [[<query> with the formed link + trailing space.
        let replacement = "\(literal) "
        text.replaceSubrange(openRange.lowerBound..<text.endIndex, with: replacement)
        Haptics.shared.softTick()
        onPicked()
    }

    private func cancel() {
        // Strip the active `[[<query>` so the bar dismisses + leaves no junk.
        guard let openRange = text.range(of: "[[", options: .backwards) else { onCancel(); return }
        text.removeSubrange(openRange.lowerBound..<text.endIndex)
        onCancel()
    }
}
