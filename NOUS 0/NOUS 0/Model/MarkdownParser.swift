import Foundation

/// Minimal markdown block parser for atom bodies. Scope: what Gemini's refine
/// pass actually emits + what users type. Explicit non-goals: tables, blockquotes,
/// code fences with language, HTML, images, footnotes.
///
/// Recognized block kinds (line-level):
///   - `# `, `## `, `### ` → heading
///   - `- [ ]` / `- [x]` → checkbox (with original line index preserved so
///     tapping can rewrite the correct line in raw text)
///   - `- ` / `* `        → bullet
///   - `1. ` / `12. `     → numbered
///   - blank line          → paragraph break
///   - anything else       → paragraph line (consecutive lines join with a space)
///
/// Inline tokens handled during render, NOT here:
///   - `[[uuid|alias]]`   (LinkParser)
///   - `**bold**`, `*italic*`, `` `code` ``
enum MarkdownParser {

    enum Block: Hashable, Sendable {
        case heading(level: Int, inline: String)
        case paragraph(inline: String)
        case bullet(inline: String)
        case numbered(number: Int, inline: String)
        /// `lineIndex` is the index in the raw-text line split (0-based) so
        /// the checkbox can round-trip to a raw-text mutation.
        case checkbox(checked: Bool, lineIndex: Int, inline: String)
    }

    static func parse(_ raw: String) -> [Block] {
        // Keep empty trailing lines out; split preserves interior blanks for paragraph breaks.
        let lines = raw.components(separatedBy: "\n")
        var out: [Block] = []
        var paraBuf: [String] = []

        func flushPara() {
            guard !paraBuf.isEmpty else { return }
            let joined = paraBuf.joined(separator: " ")
            if !joined.trimmingCharacters(in: .whitespaces).isEmpty {
                out.append(.paragraph(inline: joined))
            }
            paraBuf.removeAll()
        }

        for (idx, rawLine) in lines.enumerated() {
            let line = rawLine
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty { flushPara(); continue }

            // Headings
            if let h = matchHeading(trimmed) { flushPara(); out.append(.heading(level: h.level, inline: h.rest)); continue }

            // Checkbox (before generic bullet)
            if let cb = matchCheckbox(trimmed) {
                flushPara()
                out.append(.checkbox(checked: cb.checked, lineIndex: idx, inline: cb.rest))
                continue
            }

            // Bullet
            if let b = matchBullet(trimmed) { flushPara(); out.append(.bullet(inline: b)); continue }

            // Numbered
            if let n = matchNumbered(trimmed) { flushPara(); out.append(.numbered(number: n.number, inline: n.rest)); continue }

            // Paragraph continuation
            paraBuf.append(trimmed)
        }
        flushPara()
        return out
    }

    // MARK: - Line matchers

    private static func matchHeading(_ s: String) -> (level: Int, rest: String)? {
        var level = 0
        var idx = s.startIndex
        while idx < s.endIndex, s[idx] == "#", level < 6 {
            level += 1
            idx = s.index(after: idx)
        }
        guard level > 0, idx < s.endIndex, s[idx] == " " else { return nil }
        let rest = String(s[s.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
        return (level, rest)
    }

    private static func matchCheckbox(_ s: String) -> (checked: Bool, rest: String)? {
        // "- [ ] rest" or "- [x] rest" (also accepts "* [ ]")
        let pats: [(String, Bool)] = [
            ("- [ ] ", false), ("- [x] ", true), ("- [X] ", true),
            ("* [ ] ", false), ("* [x] ", true), ("* [X] ", true),
        ]
        for (p, checked) in pats where s.hasPrefix(p) {
            return (checked, String(s.dropFirst(p.count)))
        }
        // Handle trailing-less variants "- [ ]" (no body)
        let empties: [(String, Bool)] = [
            ("- [ ]", false), ("- [x]", true), ("- [X]", true),
            ("* [ ]", false), ("* [x]", true), ("* [X]", true),
        ]
        for (p, checked) in empties where s == p {
            return (checked, "")
        }
        return nil
    }

    private static func matchBullet(_ s: String) -> String? {
        if s.hasPrefix("- ") { return String(s.dropFirst(2)) }
        if s.hasPrefix("* ") { return String(s.dropFirst(2)) }
        return nil
    }

    private static func matchNumbered(_ s: String) -> (number: Int, rest: String)? {
        // "1. rest" through "99. rest"
        var digits = ""
        var idx = s.startIndex
        while idx < s.endIndex, s[idx].isASCII, s[idx].isNumber, digits.count < 3 {
            digits.append(s[idx]); idx = s.index(after: idx)
        }
        guard !digits.isEmpty, idx < s.endIndex, s[idx] == "." else { return nil }
        let afterDot = s.index(after: idx)
        guard afterDot < s.endIndex, s[afterDot] == " " else { return nil }
        let rest = String(s[s.index(after: afterDot)...])
        return (Int(digits) ?? 0, rest)
    }
}
