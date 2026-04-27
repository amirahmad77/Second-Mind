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

    init(content: String? = nil,
         refinedContent: String? = nil,
         type: AtomType? = nil,
         linkTargetID: UUID? = nil,
         linkKind: String? = nil,
         tags: [String]? = nil,
         taskDone: Bool? = nil,
         dueAt: Date? = nil) {
        self.content = content
        self.refinedContent = refinedContent
        self.type = type
        self.linkTargetID = linkTargetID
        self.linkKind = linkKind
        self.tags = tags
        self.taskDone = taskDone
        self.dueAt = dueAt
    }

    private enum CodingKeys: String, CodingKey {
        case content, refinedContent, type, linkTargetID, linkKind, tags, taskDone, dueAt
    }

    /// Tolerant decode: the Chrome extension / backend may ship enum values iOS
    /// doesn't know yet (e.g. `"type": "web"` for browser captures). An unknown
    /// raw enum normally throws from a non-nil `Optional<Enum>` decode — which
    /// would silently drop the whole event in the pull path. Instead: decode
    /// `type` as a raw string, best-effort map known extension values, fall
    /// back to nil on anything else.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.content         = try c.decodeIfPresent(String.self, forKey: .content)
        self.refinedContent  = try c.decodeIfPresent(String.self, forKey: .refinedContent)
        self.linkTargetID    = try c.decodeIfPresent(UUID.self,   forKey: .linkTargetID)
        self.linkKind        = try c.decodeIfPresent(String.self, forKey: .linkKind)
        self.tags            = try c.decodeIfPresent([String].self, forKey: .tags)
        self.taskDone        = try c.decodeIfPresent(Bool.self,   forKey: .taskDone)
        self.dueAt           = try c.decodeIfPresent(Date.self,   forKey: .dueAt)

        if let raw = try c.decodeIfPresent(String.self, forKey: .type) {
            if let t = AtomType(rawValue: raw) {
                self.type = t
            } else {
                // Map known extension/backend values that don't have iOS cases.
                switch raw {
                case "web", "link", "article": self.type = .reference
                default:                       self.type = nil
                }
            }
        } else {
            self.type = nil
        }
    }

    // Explicit encode — custom `init(from:)` suppresses Encodable synthesis.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(content,        forKey: .content)
        try c.encodeIfPresent(refinedContent, forKey: .refinedContent)
        try c.encodeIfPresent(type,           forKey: .type)
        try c.encodeIfPresent(linkTargetID,   forKey: .linkTargetID)
        try c.encodeIfPresent(linkKind,       forKey: .linkKind)
        try c.encodeIfPresent(tags,           forKey: .tags)
        try c.encodeIfPresent(taskDone,       forKey: .taskDone)
        try c.encodeIfPresent(dueAt,          forKey: .dueAt)
    }
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
        // Stamp the currently-effective user. Auth state is captured at event-
        // creation time; later sign-out won't retroactively change historical
        // events. AtomStore.migrateLocalUserToSignedIn rewrites pre-auth events.
        self.userID = MainActor.assumeIsolated { AppEnv.currentUserIDSync }
    }
}
