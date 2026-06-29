import Foundation
import SwiftUI

nonisolated enum AtomType: String, Codable, CaseIterable, Sendable {
    case thought, task, meeting, decision, question, reference

    @MainActor var phosphor: Color {
        switch self {
        case .thought:   NSColorToken.Phos.cyan
        case .task:      NSColorToken.Phos.green
        case .meeting:   NSColorToken.Phos.amber
        case .decision:  NSColorToken.Phos.blue
        case .question:  NSColorToken.Phos.orange
        case .reference: NSColorToken.Phos.violet
        }
    }

    var label: String { rawValue }
}

nonisolated struct SmartTag: Codable, Hashable, Sendable {
    let value: String
}

/// Projection of a note, derived from event ledger. v1 minimal shape.
nonisolated struct AtomSnapshot: Identifiable, Hashable, Sendable {
    let id: UUID
    var rawContent: String
    var refinedContent: String?
    var type: AtomType
    var tags: [SmartTag]
    var createdAt: Date
    var updatedAt: Date
    var isRefining: Bool
    var isDeleted: Bool
    /// task-specific
    var taskDone: Bool?
    var dueAt: Date?
    /// Transient (never persisted): set when refine gives up after repeated failures,
    /// cleared on a fresh/edited/successfully-refined fold or on manual retry.
    var refineFailed: Bool = false

    var displayContent: String { refinedContent ?? rawContent }

    /// True when `displayContent` has real prose beyond markdown headings and
    /// blank lines. Mirrors the backend meet-refine body guard so a heading-only
    /// stub (e.g. a bare `## session <date>`) reads as empty in the UI rather
    /// than rendering a lone title over a blank pane.
    var hasDisplayableBody: Bool {
        for line in displayContent.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty && !trimmed.hasPrefix("#") { return true }
        }
        return false
    }

    /// One-liner for Stream row. Strips markdown (block prefixes, emphasis,
    /// wikilink syntax → alias) so the preview reads like plain prose, drops a
    /// leading transcript speaker label so a raw caption never surfaces as a
    /// title verbatim, and falls back to a calm typed label when there is no
    /// usable text. Body formatting belongs in the detail surface, not the row.
    @MainActor var oneLiner: String {
        let plain = AtomSnapshot.stripSpeakerPrefix(MarkdownInline.plain(displayContent))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !plain.isEmpty { return plain }
        return type == .meeting
            ? "meeting · \(createdAt.formatted(date: .abbreviated, time: .shortened))"
            : "// \(type.label)"
    }

    /// Drop a single leading diarized speaker label ("speaker:", "Speaker 2:",
    /// "You:") so an unrefined transcript caption reads as prose in the row.
    /// Deliberately narrow — only known transcript forms — so it never strips a
    /// legitimate sentence lead like "Note:" or "TODO:".
    static func stripSpeakerPrefix(_ s: String) -> String {
        guard let m = s.firstMatch(of: #/^\s*(?:[Ss]peaker(?: \d+)?|You):\s+/#) else {
            return s
        }
        return String(s[m.range.upperBound...])
    }
}
