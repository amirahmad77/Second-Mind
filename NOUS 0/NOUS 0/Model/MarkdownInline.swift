import SwiftUI

/// Inline markdown → `AttributedString` for body rendering.
///
/// Order of passes (one left-to-right scan, no regex backtracking):
///   1. `[[uuid|alias]]` wikilink (delegated to LinkParser)
///   2. `` `inline code` ``
///   3. `**bold**`
///   4. `*italic*`
///
/// Anything that doesn't match falls through as plain text. Malformed markers
/// are emitted verbatim — we never silently eat user characters.
///
/// Wikilinks become tappable via `nous://atom/<uuid>` URLs (handled in MarkdownView's
/// OpenURLAction handler). Bold/italic/code apply standard SwiftUI attributes that
/// blend with the parent font supplied by the caller.
enum MarkdownInline {

    /// Build an attributed string for a paragraph of inline markdown text.
    /// `linkColor` tints the underline of live wikilinks; deleted targets render
    /// as ghost-strike non-interactive text.
    static func attributed(
        _ raw: String,
        store: AtomStore,
        linkColor: Color
    ) -> AttributedString {
        var out = AttributedString("")

        // Pass 1: split out [[wikilinks]] using LinkParser. Inside each text segment
        // we then apply *italic / **bold / `code` styling.
        for seg in LinkParser.segments(in: raw) {
            switch seg.kind {
            case .text(let t):
                out.append(stylize(t))
            case .link(let target, let alias):
                out.append(linkSlice(target: target, alias: alias, store: store, linkColor: linkColor))
            }
        }
        return out
    }

    // MARK: - Wikilink slice

    private static func linkSlice(target: UUID, alias: String, store: AtomStore, linkColor: Color) -> AttributedString {
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
        return slice
    }

    // MARK: - Style scanner (bold / italic / code)

    /// Single forward scan. Tracks open marker on a small stack; on close, stamps
    /// the slice with the appropriate attribute. Unbalanced markers stay literal.
    private static func stylize(_ s: String) -> AttributedString {
        var out = AttributedString("")
        var i = s.startIndex
        var buf = ""

        func flushBuf() {
            if !buf.isEmpty {
                out.append(AttributedString(buf))
                buf.removeAll(keepingCapacity: true)
            }
        }

        while i < s.endIndex {
            let c = s[i]

            // `inline code`
            if c == "`" {
                if let close = s.range(of: "`", range: s.index(after: i)..<s.endIndex) {
                    flushBuf()
                    var slice = AttributedString(String(s[s.index(after: i)..<close.lowerBound]))
                    slice.font = NFont.mono(14)
                    slice.foregroundColor = NSColorToken.Phos.cyan
                    out.append(slice)
                    i = close.upperBound
                    continue
                }
            }

            // **bold** (must be 2 stars, not 3+)
            if c == "*", s.index(after: i) < s.endIndex, s[s.index(after: i)] == "*" {
                let bodyStart = s.index(i, offsetBy: 2)
                if let close = s.range(of: "**", range: bodyStart..<s.endIndex) {
                    flushBuf()
                    var slice = AttributedString(String(s[bodyStart..<close.lowerBound]))
                    slice.font = NFont.body(currentBodySize).bold()
                    out.append(slice)
                    i = close.upperBound
                    continue
                }
            }

            // *italic* (single star, not part of a **)
            if c == "*" {
                let next = s.index(after: i)
                let after = next < s.endIndex ? s[next] : Character(" ")
                if after != "*" {
                    if let close = s.range(of: "*", range: next..<s.endIndex) {
                        flushBuf()
                        var slice = AttributedString(String(s[next..<close.lowerBound]))
                        slice.font = NFont.body(currentBodySize).italic()
                        out.append(slice)
                        i = close.upperBound
                        continue
                    }
                }
            }

            buf.append(c)
            i = s.index(after: i)
        }
        flushBuf()
        return out
    }

    /// Body font size used inside inline runs. Headings supply their own font at
    /// the block level — inline emphasis nested inside a heading should still
    /// inherit the heading size, but we keep the simpler "body inherits 17"
    /// contract here. Worst case: a *italic* span inside a `# heading` renders
    /// at body size; acceptable v1 trade.
    private static let currentBodySize: CGFloat = 17

    // MARK: - Plain text strip (for stream oneLiner)

    /// Strip block prefixes (`# `, `- [ ] `, etc.) + inline markers, replace
    /// `[[uuid|alias]]` with `alias`. For the Stream row preview where formatting
    /// would be noise.
    static func plain(_ raw: String) -> String {
        // 1. Take first non-empty line.
        guard let firstLine = raw
                .components(separatedBy: .newlines)
                .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        else { return "" }

        var s = firstLine.trimmingCharacters(in: .whitespaces)

        // 2. Strip block prefix.
        let prefixes = ["### ", "## ", "# ",
                        "- [ ] ", "- [x] ", "- [X] ",
                        "* [ ] ", "* [x] ", "* [X] ",
                        "- ", "* "]
        for p in prefixes where s.hasPrefix(p) { s = String(s.dropFirst(p.count)); break }
        // numbered list "12. "
        if let dot = s.firstIndex(of: "."), s[s.startIndex..<dot].allSatisfy(\.isNumber),
           s.index(after: dot) < s.endIndex, s[s.index(after: dot)] == " " {
            s = String(s[s.index(dot, offsetBy: 2)...])
        }

        // 2b. Strip extension-added prefixes for bare link/page saves.
        let barePrefixes = ["[link] ", "[page] "]
        for p in barePrefixes where s.hasPrefix(p) { s = String(s.dropFirst(p.count)); break }

        // 2c. Raw URL → domain/path so the row doesn't show a naked https:// string.
        if s.hasPrefix("http://") || s.hasPrefix("https://"),
           let url = URL(string: s) {
            let host = url.host ?? ""
            let path = url.path.isEmpty || url.path == "/" ? "" : url.path
            s = path.isEmpty ? host : "\(host)\(path)"
        }

        // 3. Replace [[…|alias]] → alias.
        var out = ""
        for seg in LinkParser.segments(in: s) {
            switch seg.kind {
            case .text(let t): out.append(t)
            case .link(_, let alias): out.append(alias)
            }
        }

        // 4. Strip emphasis markers (cheap: drop `**`, `*`, backticks). We don't
        // care about preserving emphasis in the row preview.
        out = out
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "`", with: "")

        return out
    }
}
