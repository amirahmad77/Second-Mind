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
    // Per-event push resilience: a single permanently-failing event (malformed
    // payload, RLS-blocked insert) must not head-of-line block the whole queue.
    private var pushAttempts: [UUID: Int] = [:]   // event id → failed push count
    private var quarantined: Set<UUID> = []       // events skipped on future drains
    private let maxPushAttempts = 5
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

    /// MIGRATION 2 — re-embed for the asymmetric taskType change. Old vectors were
    /// embedded as SEMANTIC_SIMILARITY; new ones as RETRIEVAL_DOCUMENT, so the mixed
    /// space hurts retrieval. This wipes the local embedding caches
    /// (`EmbeddingRecord` + `MeetingChunkRecord`) and re-queues `atomIDs` through the
    /// existing serialized embed pipeline so they re-embed lazily with the new
    /// taskType. Does NOT await — embedding happens in the background `embedTask`.
    ///
    /// Cost is bounded by the serialized pipeline (one Gemini request at a time) and
    /// by the caller passing only non-deleted atoms. Defensive: deletion failures are
    /// logged and swallowed so a re-index can never block launch.
    func reindexEmbeddings(atomIDs: [UUID]) {
        let embeds = (try? context.fetch(FetchDescriptor<EmbeddingRecord>())) ?? []
        for row in embeds { context.delete(row) }
        let chunks = (try? context.fetch(FetchDescriptor<MeetingChunkRecord>())) ?? []
        for row in chunks { context.delete(row) }
        do {
            try context.save()
        } catch {
            NousLogger.warning("embed", "reindex cache wipe save failed; continuing",
                               ["error": error.localizedDescription])
        }
        for id in atomIDs { scheduleEmbed(id) }
        NousLogger.info("embed", "embedding reindex queued",
                        ["queued": "\(atomIDs.count)",
                         "wipedEmbeddings": "\(embeds.count)",
                         "wipedChunks": "\(chunks.count)"])
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

    /// R8 — user-controlled sync pause. When true, `drain()` returns before pushing
    /// so events stay queued/persisted locally (never dropped) and resume pushing
    /// once cleared. Default false (missing key reads as false).
    private static var isSyncPaused: Bool {
        UserDefaults.standard.bool(forKey: "nous.settings.syncPaused")
    }

    private func drain() async {
        if draining { return }
        // R8 — honor the pause switch. Reentrancy/backoff state is left untouched so
        // the next unpaused drain resumes exactly where it left off. Queued events
        // remain unsynced in SwiftData; nothing is dropped.
        if Self.isSyncPaused {
            NousLogger.debug("sync", "drain skipped — sync paused")
            return
        }
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
            // Skip events previously quarantined after exhausting retries — they
            // stay unsynced (user data preserved) but never block the queue.
            if quarantined.contains(ev.id) { continue }
            do {
                try await supabase.pushEvent(ev)
                rec.synced = true
                try? context.save()
                backoffSeconds = 0
                pushAttempts[ev.id] = nil
            } catch {
                // Global/transient failure (offline, 5xx): keep exponential backoff
                // and stop draining — retrying other events now would also fail.
                if Self.isTransient(error) {
                    backoffSeconds = min(maxBackoff, max(2, backoffSeconds * 2))
                    NousLogger.error("sync", "drain push failed (transient), backoff \(backoffSeconds)s",
                                     ["error": error.localizedDescription])
                    return
                }
                // Per-event/permanent failure (4xx, RLS-blocked insert): count the
                // attempt, log, and CONTINUE so one bad event can't stall the queue.
                let attempts = (pushAttempts[ev.id] ?? 0) + 1
                pushAttempts[ev.id] = attempts
                if attempts >= maxPushAttempts {
                    quarantined.insert(ev.id)
                    pushAttempts[ev.id] = nil
                    NousLogger.error("sync", "drain push quarantined event after \(attempts) attempts",
                                     ["eventID": ev.id.uuidString, "kind": ev.kind.rawValue,
                                      "error": error.localizedDescription])
                } else {
                    NousLogger.warning("sync", "drain push failed (per-event), skipping",
                                       ["eventID": ev.id.uuidString, "kind": ev.kind.rawValue,
                                        "attempt": attempts, "error": error.localizedDescription])
                }
                continue
            }
        }
    }

    /// Distinguishes a global/transient failure (network down, server 5xx) — where
    /// the existing backoff-and-return behavior is correct — from a per-event
    /// permanent failure (4xx, malformed payload, RLS rejection) — where we skip
    /// and continue. When the status is unknown, treat it as transient so we never
    /// quarantine an event that might actually succeed once connectivity returns.
    private static func isTransient(_ error: Error) -> Bool {
        if error is URLError { return true } // connectivity, timeout, DNS, etc.
        let ns = error as NSError
        // SupabaseClient.check throws NSError(domain: "Supabase", code: <statusCode>).
        if ns.domain == "Supabase" {
            let status = ns.code
            if (400..<500).contains(status) { return false } // 4xx → permanent
            return true                                       // 5xx / unknown → transient
        }
        // RLS-blocked insert (Supabase.pushEvent, code 0) is a permanent config issue.
        if ns.domain == "Supabase.pushEvent" { return false }
        // Unknown error origin: err on the side of retrying.
        return true
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

        // Long atoms (meetings, long notes) additionally fan out into per-passage
        // chunk vectors so retrieval can surface a specific passage. Resilient:
        // failures log + skip and never block the main embed above.
        let isMeeting = Self.reconstructType(rows) == .meeting
        if isMeeting || text.count > Self.chunkLengthThreshold {
            await embedChunks(atomID: atomID, text: text)
        }
    }

    // MARK: - Meeting transcript chunking

    /// Atoms longer than this (chars) warrant chunked embedding even when not typed
    /// as `.meeting`. ~1500 chars keeps each passage well under the embed token cap.
    private static let chunkLengthThreshold = 1500
    private static let chunkTargetChars = 1500
    private static let chunkOverlapChars = 100
    /// Bound cost: at most this many chunk embeddings per atom.
    private static let maxChunksPerAtom = 40

    /// Splits `text` into passages and embeds each one sequentially on the existing
    /// serialized embed pipeline (this runs inside `embedTask`, so no parallel
    /// Gemini fan-out). Deletes prior chunks for the atom first to avoid dupes on
    /// re-embed. Per-passage failures are logged and skipped.
    private func embedChunks(atomID: UUID, text: String) async {
        var passages = Self.chunk(text)
        guard !passages.isEmpty else { return }
        if passages.count > Self.maxChunksPerAtom {
            NousLogger.warning("sync", "meeting chunks capped",
                               ["atomID": atomID.uuidString,
                                "produced": passages.count,
                                "cap": Self.maxChunksPerAtom])
            passages = Array(passages.prefix(Self.maxChunksPerAtom))
        }

        // Dedupe on re-embed: drop any existing chunk rows for this atom first.
        let existingDesc = FetchDescriptor<MeetingChunkRecord>(
            predicate: #Predicate { $0.atomID == atomID })
        let existing = (try? context.fetch(existingDesc)) ?? []
        for row in existing { context.delete(row) }
        if !existing.isEmpty { try? context.save() }

        var stored = 0
        for (index, passage) in passages.enumerated() {
            let trimmed = passage.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 16 else { continue } // skip trivial fragments
            do {
                let vec = try await gemini.embed(trimmed, taskType: .document)
                let rec = MeetingChunkRecord(
                    atomID: atomID, chunkIndex: index, text: trimmed, dim: vec.count,
                    vector: Data(bytes: vec, count: vec.count * MemoryLayout<Float>.size))
                context.insert(rec)
                stored += 1
            } catch {
                NousLogger.error("sync", "chunk embed failed",
                                 ["atomID": atomID.uuidString, "chunk": index,
                                  "error": error.localizedDescription])
                continue
            }
        }
        if stored > 0 {
            try? context.save()
            NousLogger.info("sync", "meeting chunks embedded",
                            ["atomID": atomID.uuidString, "chunks": stored])
        }
    }

    /// Deterministic passage splitter. Accumulates paragraph/sentence segments into
    /// ~`chunkTargetChars` windows, carrying ~`chunkOverlapChars` of trailing context
    /// into the next window so a fact straddling a boundary survives in both.
    static func chunk(_ text: String,
                      target: Int = SyncDaemon.chunkTargetChars,
                      overlap: Int = SyncDaemon.chunkOverlapChars) -> [String] {
        let segments = splitSegments(text)
        guard !segments.isEmpty else { return [] }

        var passages: [String] = []
        var current = ""
        for seg in segments {
            if current.isEmpty {
                current = seg
            } else if current.count + 1 + seg.count <= target {
                current += " " + seg
            } else {
                passages.append(current)
                // Carry an overlap tail from the just-closed passage.
                let tail = overlap > 0 ? String(current.suffix(overlap)) : ""
                current = tail.isEmpty ? seg : tail + " " + seg
            }
        }
        if !current.isEmpty { passages.append(current) }
        return passages
    }

    /// Breaks text on paragraph boundaries first, then sentence boundaries, then
    /// hard-slices any single segment that still exceeds the target window.
    private static func splitSegments(_ text: String) -> [String] {
        let paragraphs = text
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var out: [String] = []
        for para in paragraphs {
            if para.count <= chunkTargetChars { out.append(para); continue }
            // Sentence-level split for oversized paragraphs.
            var sentence = ""
            for ch in para {
                sentence.append(ch)
                if ch == "." || ch == "!" || ch == "?" {
                    let s = sentence.trimmingCharacters(in: .whitespaces)
                    if !s.isEmpty { out.append(s) }
                    sentence = ""
                }
            }
            let tail = sentence.trimmingCharacters(in: .whitespaces)
            if !tail.isEmpty { out.append(tail) }
        }

        // Final guard: hard-slice any segment still larger than the target so a
        // single run-on never produces an oversized embed request.
        return out.flatMap { seg -> [String] in
            guard seg.count > chunkTargetChars else { return [seg] }
            var pieces: [String] = []
            var rest = Substring(seg)
            while !rest.isEmpty {
                let end = rest.index(rest.startIndex,
                                     offsetBy: chunkTargetChars,
                                     limitedBy: rest.endIndex) ?? rest.endIndex
                pieces.append(String(rest[rest.startIndex..<end]))
                rest = rest[end...]
            }
            return pieces
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

    /// Newest known atom type from the event ledger (refine/typeChanged carry it).
    private static func reconstructType(_ rows: [NoteEventRecord]) -> AtomType? {
        for r in rows {
            guard let e = r.toEvent() else { continue }
            if let t = e.payload.type { return t }
        }
        return nil
    }
}
