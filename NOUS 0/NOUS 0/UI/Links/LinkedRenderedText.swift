import SwiftUI

/// Renders an atom body as styled markdown blocks with tappable `[[uuid|alias]]`
/// inline links. Minimal set per PRD: headings, bullets, numbered lists,
/// interactive checkboxes, inline bold / italic / code, wikilinks.
///
/// Checkbox taps mutate the raw text through `store.updateRaw` — callers must
/// pass `atomID` for this to work; otherwise the box renders but is inert.
struct LinkedRenderedText: View {
    let raw: String
    let store: AtomStore
    var atomID: UUID? = nil
    let linkColor: Color
    let onPickAtom: (AtomSnapshot) -> Void

    init(raw: String,
         store: AtomStore,
         atomID: UUID? = nil,
         linkColor: Color = NSColorToken.Phos.cyan,
         onPickAtom: @escaping (AtomSnapshot) -> Void) {
        self.raw = raw
        self.store = store
        self.atomID = atomID
        self.linkColor = linkColor
        self.onPickAtom = onPickAtom
    }

    var body: some View {
        let blocks = MarkdownParser.parse(raw)
        VStack(alignment: .leading, spacing: NSpace.sm) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                render(block)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .environment(\.openURL, urlAction)
    }

    // MARK: - Block render

    @ViewBuilder private func render(_ block: MarkdownParser.Block) -> some View {
        switch block {
        case .heading(let level, let inline):
            Text(attributed(inline, baseWeight: .semibold))
                .font(headingFont(level))
                .foregroundStyle(NSColorToken.textPrimary)
                .padding(.top, level == 1 ? NSpace.xs : 0)

        case .paragraph(let inline):
            Text(attributed(inline))

        case .bullet(let inline):
            HStack(alignment: .firstTextBaseline, spacing: NSpace.sm) {
                Text("•")
                    .foregroundStyle(NSColorToken.textTertiary)
                Text(attributed(inline))
            }

        case .numbered(let n, let inline):
            HStack(alignment: .firstTextBaseline, spacing: NSpace.sm) {
                Text("\(n).")
                    .monospacedDigit()
                    .foregroundStyle(NSColorToken.textTertiary)
                Text(attributed(inline))
            }

        case .checkbox(let checked, let lineIndex, let inline):
            HStack(alignment: .firstTextBaseline, spacing: NSpace.sm) {
                Button {
                    toggleCheckbox(lineIndex: lineIndex, currentlyChecked: checked)
                } label: {
                    Image(systemName: checked ? "checkmark.square.fill" : "square")
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(checked ? NSColorToken.Phos.green : NSColorToken.textTertiary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(atomID == nil)
                Text(attributed(inline))
                    .strikethrough(checked, color: NSColorToken.textTertiary)
                    .foregroundStyle(checked ? NSColorToken.textTertiary : NSColorToken.textPrimary)
            }
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return NFont.body(22).weight(.semibold)
        case 2: return NFont.body(19).weight(.semibold)
        default: return NFont.body(17).weight(.semibold)
        }
    }

    // MARK: - Checkbox mutation

    private func toggleCheckbox(lineIndex: Int, currentlyChecked: Bool) {
        guard let atomID else { return }
        var lines = raw.components(separatedBy: "\n")
        guard lineIndex < lines.count else { return }
        let line = lines[lineIndex]
        let rewritten: String
        if currentlyChecked {
            // Replace first [x]/[X] on the line with [ ]
            rewritten = line
                .replacingOccurrences(of: "[x]", with: "[ ]")
                .replacingOccurrences(of: "[X]", with: "[ ]")
        } else {
            rewritten = line.replacingOccurrences(of: "[ ]", with: "[x]")
        }
        guard rewritten != line else { return }
        lines[lineIndex] = rewritten
        store.updateRaw(id: atomID, newContent: lines.joined(separator: "\n"))
        Haptics.shared.softTick()
    }

    // MARK: - Inline attributed builder

    /// Builds an AttributedString for one block's inline content. Supports
    /// wikilinks, `**bold**`, `*italic*`, `` `code` ``. Nesting is intentionally
    /// NOT supported — first match wins, so `**a *b* c**` renders as bold "a *b* c".
    private func attributed(_ inline: String, baseWeight: Font.Weight = .regular) -> AttributedString {
        var out = AttributedString("")
        for seg in LinkParser.segments(in: inline) {
            switch seg.kind {
            case .text(let t):
                out.append(formatInline(t))
            case .link(let target, let alias):
                let isLive = store.atoms[target] != nil && store.atoms[target]?.isDeleted == false
                var slice = AttributedString(alias)
                if isLive {
                    slice.foregroundColor = NSColorToken.textPrimary
                    slice.underlineStyle = .single
                    slice.link = URL(string: "nous://atom/\(target.uuidString)")
                } else {
                    slice.foregroundColor = NSColorToken.textGhost
                    slice.strikethroughStyle = .single
                }
                out.append(slice)
            }
        }
        return out
    }

    /// Scans a plain-text segment for `**bold**`, `*italic*`, `` `code` `` and
    /// emits styled AttributedString pieces in order. Minimal state machine —
    /// matches first delimiter seen, does not nest.
    private func formatInline(_ s: String) -> AttributedString {
        var out = AttributedString("")
        var i = s.startIndex
        while i < s.endIndex {
            // Bold `**...**`
            if s[i...].hasPrefix("**"),
               let end = s.range(of: "**", range: s.index(i, offsetBy: 2)..<s.endIndex) {
                let body = String(s[s.index(i, offsetBy: 2)..<end.lowerBound])
                var slice = AttributedString(body)
                slice.inlinePresentationIntent = .stronglyEmphasized
                out.append(slice)
                i = end.upperBound
                continue
            }
            // Code `` `...` ``
            if s[i] == "`",
               let end = s.range(of: "`", range: s.index(after: i)..<s.endIndex) {
                let body = String(s[s.index(after: i)..<end.lowerBound])
                var slice = AttributedString(body)
                slice.inlinePresentationIntent = .code
                slice.foregroundColor = NSColorToken.Phos.amber
                out.append(slice)
                i = end.upperBound
                continue
            }
            // Italic `*...*` (single asterisk; skip if followed by another *)
            if s[i] == "*",
               s.index(after: i) < s.endIndex,
               s[s.index(after: i)] != "*",
               let end = s.range(of: "*", range: s.index(after: i)..<s.endIndex) {
                let body = String(s[s.index(after: i)..<end.lowerBound])
                var slice = AttributedString(body)
                slice.inlinePresentationIntent = .emphasized
                out.append(slice)
                i = end.upperBound
                continue
            }
            // Underscore italic `_..._`
            if s[i] == "_",
               let end = s.range(of: "_", range: s.index(after: i)..<s.endIndex) {
                let body = String(s[s.index(after: i)..<end.lowerBound])
                var slice = AttributedString(body)
                slice.inlinePresentationIntent = .emphasized
                out.append(slice)
                i = end.upperBound
                continue
            }
            // Default: append one char
            out.append(AttributedString(String(s[i])))
            i = s.index(after: i)
        }
        return out
    }

    // MARK: - URL action

    private var urlAction: OpenURLAction {
        OpenURLAction { url in
            guard url.scheme == "nous", url.host == "atom" else { return .systemAction }
            let idStr = String(url.path.dropFirst())
            guard let uuid = UUID(uuidString: idStr), let atom = store.atoms[uuid] else {
                Haptics.shared.softTick()
                return .handled
            }
            onPickAtom(atom)
            return .handled
        }
    }
}
