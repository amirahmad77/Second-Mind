import Foundation
import SwiftData

/// Invisible background sync. Pushes unsynced NoteEventRecords to Supabase.
/// Never surfaces errors to UI. Retries silently on next enqueue / bootstrap.
@MainActor
final class SyncDaemon {
    private let context: ModelContext
    private let supabase: SupabaseClient
    private let gemini: GeminiClient
    private var draining = false
    private var backoffSeconds: UInt64 = 0
    private let maxBackoff: UInt64 = 300 // 5 min ceiling
    private var pendingEmbedIDs: Set<UUID> = []   // dedupe enqueues
    private var embedTask: Task<Void, Never>?     // serialize embed pipeline

    /// Closure invoked on the MainActor for each fresh remote event pulled from
    /// Supabase. AtomStore wires this to fold remote captures (Chrome extension,
    /// future web) into its in-memory state.
    var onRemoteEvent: ((NoteEvent) -> Void)?

    private static let pullCursorKey = "nous.sync.lastPullCursor"
    static let lastPullAtKey      = "nous.sync.lastPullAt"
    static let lastPullCountKey   = "nous.sync.lastPullCount"
    static let lastPullErrorKey   = "nous.sync.lastPullError"
    static let lastPullUserKey    = "nous.sync.lastPullUserID"
    private var pulling = false

    /// Force-resync: clears the cursor so the next pull walks the last 30 days
    /// of events from Supabase. Used when something out-of-band (Chrome
    /// extension, web) wrote events but the local cursor moved past them.
    func resetPullCursor() {
        UserDefaults.standard.removeObject(forKey: Self.pullCursorKey)
    }

    /// Manual immediate pull. Convenience for a "resync now" Settings button.
    func pullNowAndWait() async { await pull() }

    init(context: ModelContext, supabase: SupabaseClient, gemini: GeminiClient) {
        self.context = context; self.supabase = supabase; self.gemini = gemini
    }

    func bootstrap() {
        Task { await drain() }
        Task { await pull() }
        // Periodic drain + pull catches offline → online transitions and surfaces
        // captures originating outside the device (Chrome extension, future web).
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
                await self?.drain()
                await self?.pull()
            }
        }
    }

    /// Manually triggered pull (e.g. on app foreground). Coalesces concurrent calls.
    func pullNow() { Task { await pull() } }

    private func pull() async {
        if pulling { return }
        pulling = true
        defer {
            pulling = false
            UserDefaults.standard.set(Date(), forKey: Self.lastPullAtKey)
        }

        // Stamp the user_id we're about to query under, so Settings can show
        // the user whether iOS and the extension are using the same identity.
        let uid = await AppEnv.currentUserID()
        UserDefaults.standard.set(uid.uuidString, forKey: Self.lastPullUserKey)

        let cursor = (UserDefaults.standard.object(forKey: Self.pullCursorKey) as? Date)
            ?? Date(timeIntervalSinceNow: -60 * 60 * 24 * 30) // first run: last 30d
        let events: [NoteEvent]
        do { events = try await supabase.fetchEvents(since: cursor, limit: 500) }
        catch {
            UserDefaults.standard.set(error.localizedDescription, forKey: Self.lastPullErrorKey)
            NousLogger.error("sync", "pull failed", ["error": error.localizedDescription])
            return
        }
        UserDefaults.standard.removeObject(forKey: Self.lastPullErrorKey)
        UserDefaults.standard.set(events.count, forKey: Self.lastPullCountKey)
        guard !events.isEmpty else { return }
        NousLogger.info("sync", "pulled \(events.count) remote events")

        var maxCreated = cursor
        for e in events {
            if e.createdAt > maxCreated { maxCreated = e.createdAt }
            // Dedupe by event id — drain() already pushed local events here, the
            // server echoes them back. Skip if already in SwiftData.
            let eid = e.id
            let dupDesc = FetchDescriptor<NoteEventRecord>(predicate: #Predicate { $0.id == eid })
            let existing = (try? context.fetch(dupDesc)) ?? []
            if !existing.isEmpty { continue }

            // Persist as already-synced (came from cloud).
            let rec = NoteEventRecord.from(e)
            rec.synced = true
            context.insert(rec)
            onRemoteEvent?(e)
        }
        try? context.save()
        UserDefaults.standard.set(maxCreated, forKey: Self.pullCursorKey)
    }

    func enqueue(_ rec: NoteEventRecord) {
        Task { await drain() }
        if rec.kindRaw == NoteEventKind.refined.rawValue || rec.kindRaw == NoteEventKind.created.rawValue {
            scheduleEmbed(rec.atomID)
        }
    }

    /// Coalesces rapid edits to the same atom and serializes the embed pipeline
    /// — N captures don't spawn N parallel Gemini requests.
    private func scheduleEmbed(_ id: UUID) {
        pendingEmbedIDs.insert(id)
        guard embedTask == nil else { return }
        embedTask = Task { [weak self] in
            while let self, let next = await self.popEmbedID() {
                await self.embedAtom(next)
            }
            await MainActor.run { [weak self] in self?.embedTask = nil }
        }
    }

    private func popEmbedID() -> UUID? {
        guard let id = pendingEmbedIDs.first else { return nil }
        pendingEmbedIDs.remove(id)
        return id
    }

    private func drain() async {
        if draining { return }
        if backoffSeconds > 0 {
            try? await Task.sleep(nanoseconds: backoffSeconds * 1_000_000_000)
        }
        draining = true
        defer { draining = false }
        let desc = FetchDescriptor<NoteEventRecord>(predicate: #Predicate { !$0.synced },
                                                    sortBy: [SortDescriptor(\.createdAt, order: .forward)])
        let pending = (try? context.fetch(desc)) ?? []
        for rec in pending {
            guard let ev = rec.toEvent() else { rec.synced = true; continue }
            do {
                try await supabase.pushEvent(ev)
                rec.synced = true
                try? context.save()
                backoffSeconds = 0
            } catch {
                // Exponential backoff: 2 → 4 → 8 … capped at 5 min.
                backoffSeconds = min(maxBackoff, max(2, backoffSeconds * 2))
                NousLogger.error("sync", "drain push failed, backoff \(backoffSeconds)s", ["error": error.localizedDescription])
                return
            }
        }
    }

    private func embedAtom(_ atomID: UUID) async {
        // Locate current raw/refined text via store? Here we fetch latest created/refined event directly.
        let desc = FetchDescriptor<NoteEventRecord>(
            predicate: #Predicate { $0.atomID == atomID },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        let rows = (try? context.fetch(desc)) ?? []
        guard let text = Self.reconstructText(rows) else { return }
        do {
            let vec = try await gemini.embed(text)
            try await supabase.upsertEmbedding(atomID: atomID, vector: vec)
            let cache = EmbeddingRecord(atomID: atomID, dim: vec.count,
                                        vector: Data(bytes: vec, count: vec.count * MemoryLayout<Float>.size))
            context.insert(cache)
            try? context.save()
        } catch {
            NousLogger.error("sync", "embed failed", ["atomID": atomID.uuidString, "error": error.localizedDescription])
        }
    }

    private static func reconstructText(_ rows: [NoteEventRecord]) -> String? {
        var raw: String?; var refined: String?
        for r in rows {
            guard let e = r.toEvent() else { continue }
            if refined == nil, e.kind == .refined, let rc = e.payload.refinedContent, !rc.isEmpty { refined = rc }
            if raw == nil, (e.kind == .created || e.kind == .updatedRaw), let c = e.payload.content { raw = c }
            if refined != nil && raw != nil { break }
        }
        return refined ?? raw
    }
}
