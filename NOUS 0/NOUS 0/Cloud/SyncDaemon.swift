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

    init(context: ModelContext, supabase: SupabaseClient, gemini: GeminiClient) {
        self.context = context; self.supabase = supabase; self.gemini = gemini
    }

    func bootstrap() {
        Task { await drain() }
        // Periodic drain catches offline → online transitions without NW reachability dep.
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                await self?.drain()
            }
        }
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
            // silent
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
