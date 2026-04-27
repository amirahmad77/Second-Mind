import Foundation

/// Wikilink syntax: `[[<uuid>|<alias>]]`
///
/// We never use raw `[[alias]]` (no UUID). Storage format is always the explicit
/// UUID form, so target lookup is O(1) and survives target rename.
///
/// Parser is forgiving: malformed `[[ ]]` segments are left as plain text in
/// the rendered output. Aliases may contain any character except `]]`.
enum LinkParser {

    struct Segment: Hashable, Sendable {
        enum Kind: Hashable, Sendable {
            case text(String)
            case link(target: UUID, alias: String)
        }
        let kind: Kind
    }

    /// Splits raw text into ordered text + link segments.
    static func segments(in raw: String) -> [Segment] {
        guard !raw.isEmpty else { return [] }
        var out: [Segment] = []
        var cursor = raw.startIndex

        while let openRange = raw.range(of: "[[", range: cursor..<raw.endIndex) {
            // Emit preceding text segment.
            if openRange.lowerBound > cursor {
                let pre = String(raw[cursor..<openRange.lowerBound])
                out.append(Segment(kind: .text(pre)))
            }

            // Find closing `]]` after this opening.
            guard let closeRange = raw.range(of: "]]", range: openRange.upperBound..<raw.endIndex) else {
                // Unclosed `[[` — treat the rest as text.
                out.append(Segment(kind: .text(String(raw[openRange.lowerBound..<raw.endIndex]))))
                cursor = raw.endIndex
                break
            }

            let inner = String(raw[openRange.upperBound..<closeRange.lowerBound])
            if let parsed = parseInner(inner) {
                out.append(Segment(kind: .link(target: parsed.uuid, alias: parsed.alias)))
            } else {
                // Malformed — keep raw `[[…]]` as text.
                out.append(Segment(kind: .text(String(raw[openRange.lowerBound..<closeRange.upperBound]))))
            }
            cursor = closeRange.upperBound
        }

        if cursor < raw.endIndex {
            out.append(Segment(kind: .text(String(raw[cursor..<raw.endIndex]))))
        }
        return out
    }

    /// All outbound link targets (deduped, in order).
    static func outboundTargets(in raw: String) -> [UUID] {
        var seen: Set<UUID> = []
        var out: [UUID] = []
        for seg in segments(in: raw) {
            if case .link(let id, _) = seg.kind, !seen.contains(id) {
                seen.insert(id); out.append(id)
            }
        }
        return out
    }

    /// Construct the wire literal for a new link. Alias whitespace is collapsed +
    /// `]]` substrings stripped so we never produce ambiguous syntax.
    static func literal(target: UUID, alias: String) -> String {
        let safe = alias
            .replacingOccurrences(of: "]]", with: "]")
            .split(whereSeparator: \.isNewline)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        let display = safe.isEmpty ? "atom" : safe
        return "[[\(target.uuidString)|\(display)]]"
    }

    // MARK: - Internals

    private static func parseInner(_ s: String) -> (uuid: UUID, alias: String)? {
        guard let pipe = s.firstIndex(of: "|") else { return nil }
        let uuidStr = String(s[s.startIndex..<pipe])
            .trimmingCharacters(in: .whitespaces)
        let alias = String(s[s.index(after: pipe)..<s.endIndex])
            .trimmingCharacters(in: .whitespaces)
        guard let uuid = UUID(uuidString: uuidStr), !alias.isEmpty else { return nil }
        return (uuid, alias)
    }
}
