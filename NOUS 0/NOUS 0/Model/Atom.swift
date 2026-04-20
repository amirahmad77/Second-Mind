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

    var displayContent: String { refinedContent ?? rawContent }

    /// One-liner for Stream row.
    var oneLiner: String {
        let src = displayContent.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = src.split(whereSeparator: \.isNewline).first { return String(first) }
        return src
    }
}
