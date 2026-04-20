import Foundation
import SwiftData
import Observation

/// Fold events → atom projections. In-memory dictionary, rebuilt on load, mutated on each append.
@Observable
@MainActor
final class AtomStore {
    private(set) var atoms: [UUID: AtomSnapshot] = [:]
    /// Ordered newest-first for Stream.
    private(set) var ordered: [AtomSnapshot] = []

    /// Memoization for Stream grouping. Invalidated whenever ordered/filter changes.
    private var groupCache: (filter: String, version: Int, value: [DayGroup])?
    private var version: Int = 0

    private let context: ModelContext
    private let sync: SyncDaemon
    private let gemini: GeminiClient

    init(context: ModelContext, sync: SyncDaemon, gemini: GeminiClient) {
        self.context = context
        self.sync = sync
        self.gemini = gemini
    }

    func bootstrap() {
        let desc = FetchDescriptor<NoteEventRecord>(sortBy: [SortDescriptor(\.createdAt, order: .forward)])
        let rows = (try? context.fetch(desc)) ?? []
        for row in rows { if let e = row.toEvent() { apply(e, persist: false) } }
        rebuildOrdered()
    }

    // MARK: - Public mutations

    /// Max capture size — guards against runaway paste (logs, binaries).
    static let maxCaptureBytes = 64 * 1024

    @discardableResult
    func capture(raw: String, type: AtomType = .thought) -> AtomSnapshot? {
        let normalized = Self.normalize(raw)
        guard !normalized.isEmpty else { return nil }
        let id = UUID()
        let ev = NoteEvent(atomID: id, kind: .created, payload: .init(content: normalized, type: type))
        apply(ev, persist: true)
        rebuildOrdered()
        startRefine(id: id, raw: normalized)
        return atoms[id]
    }

    func updateRaw(id: UUID, newContent: String) {
        let normalized = Self.normalize(newContent)
        guard !normalized.isEmpty else { return }
        guard atoms[id]?.rawContent != normalized else { return }
        let ev = NoteEvent(atomID: id, kind: .updatedRaw, payload: .init(content: normalized))
        apply(ev, persist: true)
        startRefine(id: id, raw: normalized)
    }

    private static func normalize(_ s: String) -> String {
        var out = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if out.utf8.count > maxCaptureBytes {
            let prefix = out.prefix(maxCaptureBytes / 4) // UTF-16 unit budget; safe upper bound
            out = String(prefix) + "…"
        }
        return out
    }

    func revertToRaw(id: UUID) {
        // Mark isRefining false; clear refinedContent by writing a refined(nil) sentinel event.
        let ev = NoteEvent(atomID: id, kind: .refined, payload: .init(refinedContent: ""))
        apply(ev, persist: true)
    }

    func toggleTask(id: UUID) {
        guard let a = atoms[id] else { return }
        let done = !(a.taskDone ?? false)
        let ev = NoteEvent(atomID: id, kind: .taskToggled, payload: .init(taskDone: done))
        apply(ev, persist: true)
    }

    func delete(id: UUID) {
        let ev = NoteEvent(atomID: id, kind: .deleted, payload: .init())
        apply(ev, persist: true)
        rebuildOrdered()
    }

    // MARK: - Fold

    private func apply(_ e: NoteEvent, persist: Bool) {
        var a = atoms[e.atomID] ?? AtomSnapshot(
            id: e.atomID, rawContent: "", refinedContent: nil,
            type: .thought, tags: [], createdAt: e.createdAt, updatedAt: e.createdAt,
            isRefining: false, isDeleted: false, taskDone: nil, dueAt: nil
        )
        switch e.kind {
        case .created:
            a.rawContent = e.payload.content ?? ""
            a.type = e.payload.type ?? .thought
            a.createdAt = e.createdAt
            a.isRefining = true
        case .updatedRaw:
            a.rawContent = e.payload.content ?? a.rawContent
            a.isRefining = true
        case .refined:
            let r = e.payload.refinedContent ?? ""
            a.refinedContent = r.isEmpty ? nil : r
            a.isRefining = false
        case .typeChanged:
            if let t = e.payload.type { a.type = t }
        case .tagged:
            a.tags = (e.payload.tags ?? []).map { SmartTag(value: $0) }
        case .taskToggled:
            a.taskDone = e.payload.taskDone
            if a.type != .task { a.type = .task }
        case .dueSet:
            a.dueAt = e.payload.dueAt
        case .linked:
            break // v1 no UI for backlinks beyond count; skip
        case .deleted:
            a.isDeleted = true
        }
        a.updatedAt = e.createdAt
        atoms[e.atomID] = a
        // Mutation may invalidate filter results / mtg counts.
        version &+= 1
        groupCache = nil

        if persist {
            let rec = NoteEventRecord.from(e)
            context.insert(rec)
            try? context.save()
            sync.enqueue(rec)
        }
    }

    private func rebuildOrdered() {
        ordered = atoms.values
            .filter { !$0.isDeleted }
            .sorted { $0.createdAt > $1.createdAt }
        version &+= 1
        groupCache = nil
    }

    // MARK: - Refine

    private func startRefine(id: UUID, raw: String) {
        // Skip refine on trivially short captures — no value, burns rate limit.
        guard raw.count >= 8 else {
            let ev = NoteEvent(atomID: id, kind: .refined, payload: .init(refinedContent: ""))
            apply(ev, persist: true)
            return
        }
        Task.detached { [gemini] in
            guard let refined = try? await gemini.refine(raw: raw) else {
                // Clear isRefining even on failure so UI doesn't hang.
                await MainActor.run {
                    let ev = NoteEvent(atomID: id, kind: .refined, payload: .init(refinedContent: ""))
                    self.apply(ev, persist: true)
                }
                return
            }
            await MainActor.run {
                let ev = NoteEvent(atomID: id, kind: .refined, payload: .init(refinedContent: refined))
                self.apply(ev, persist: true)
            }
        }
    }

    // MARK: - Stream grouping

    struct DayGroup: Identifiable {
        var id: Date { day }
        let day: Date
        let atoms: [AtomSnapshot]
        var mtgCount: Int { atoms.filter { $0.type == .meeting }.count }
    }

    func groupedByDay(filter: String? = nil) -> [DayGroup] {
        let key = filter?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if let c = groupCache, c.filter == key, c.version == version { return c.value }

        let cal = Calendar.current
        let source: [AtomSnapshot]
        if !key.isEmpty {
            source = ordered.filter { $0.displayContent.lowercased().contains(key) }
        } else {
            source = ordered
        }
        let buckets = Dictionary(grouping: source) { cal.startOfDay(for: $0.createdAt) }
        let result = buckets.keys.sorted(by: >).map { DayGroup(day: $0, atoms: buckets[$0] ?? []) }
        groupCache = (key, version, result)
        return result
    }

    // Convenience
    var taskAtoms: [AtomSnapshot] { ordered.filter { $0.type == .task } }
}
