import Foundation

/// Immutable event-sourced ledger. Append-only. Conflict-free by construction.
nonisolated enum NoteEventKind: String, Codable, Sendable {
    case created, updatedRaw, refined, typeChanged, linked, tagged, taskToggled, dueSet, deleted
}

nonisolated struct NoteEventPayload: Codable, Sendable {
    // Only relevant fields per kind; all optional, decoded sparse.
    var content: String?
    var refinedContent: String?
    var type: AtomType?
    var linkTargetID: UUID?
    var linkKind: String?
    var tags: [String]?
    var taskDone: Bool?
    var dueAt: Date?
}

/// On-device event envelope. Stored in SwiftData as a record; pushed to Supabase `events` table.
nonisolated struct NoteEvent: Codable, Identifiable, Sendable {
    let id: UUID           // event id
    let atomID: UUID       // note id
    let kind: NoteEventKind
    let payload: NoteEventPayload
    let createdAt: Date
    let userID: UUID

    init(atomID: UUID, kind: NoteEventKind, payload: NoteEventPayload = .init(), at: Date = Date()) {
        self.id = UUID()
        self.atomID = atomID
        self.kind = kind
        self.payload = payload
        self.createdAt = at
        self.userID = AppEnv.localUserID
    }
}
