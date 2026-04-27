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
    /// target → set of source IDs that link to it
    private var inboundLinks: [UUID: Set<UUID>] = [:]

    /// Memoization for Stream grouping. Invalidated whenever ordered/filter changes.
    private var groupCache: (filter: String, tag: String, version: Int, value: [DayGroup])?
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
        // Re-queue refine for atoms orphaned mid-refine (app killed during Gemini call).
        // Their .created event set isRefining=true but no .refined event was ever persisted.
        for atom in atoms.values where atom.isRefining && !atom.isDeleted {
            startRefine(id: atom.id, raw: atom.rawContent)
        }
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

    func toggleChecklistItem(id: UUID, lineIndex: Int) {
        guard let a = atoms[id] else { return }
        let content = a.refinedContent ?? a.rawContent
        var lines = content.components(separatedBy: "\n")
        guard lineIndex < lines.count else { return }
        let line = lines[lineIndex]
        if line.contains("- [ ]") {
            lines[lineIndex] = line.replacingOccurrences(of: "- [ ]", with: "- [x]", options: .literal)
        } else if line.contains("- [x]") || line.contains("- [X]") {
            lines[lineIndex] = line
                .replacingOccurrences(of: "- [x]", with: "- [ ]", options: .literal)
                .replacingOccurrences(of: "- [X]", with: "- [ ]", options: .literal)
        } else { return }
        let updated = lines.joined(separator: "\n")
        let ev = NoteEvent(atomID: id, kind: .updatedRaw, payload: .init(content: updated))
        apply(ev, persist: true)
    }

    func setDue(for id: UUID, days: Int) {
        let cal = Calendar.current
        let due = cal.startOfDay(for: cal.date(byAdding: .day, value: days, to: Date()) ?? Date())
        let ev = NoteEvent(atomID: id, kind: .dueSet, payload: .init(dueAt: due))
        apply(ev, persist: true)
    }

    func setDue(id: UUID, to date: Date?) {
        let ev = NoteEvent(atomID: id, kind: .dueSet, payload: .init(dueAt: date))
        apply(ev, persist: true)
    }

    func delete(id: UUID) {
        let ev = NoteEvent(atomID: id, kind: .deleted, payload: .init())
        apply(ev, persist: true)
        rebuildOrdered()
    }

    func addTag(id: UUID, tag: String) {
        guard let atom = atoms[id] else { return }
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return }
        var current = atom.tags.map(\.value)
        guard !current.contains(trimmed) else { return }
        current.append(trimmed)
        let ev = NoteEvent(atomID: id, kind: .tagged, payload: .init(tags: current))
        apply(ev, persist: true)
    }

    func removeTag(id: UUID, tag: String) {
        guard let atom = atoms[id] else { return }
        let remaining = atom.tags.map(\.value).filter { $0 != tag }
        let ev = NoteEvent(atomID: id, kind: .tagged, payload: .init(tags: remaining))
        apply(ev, persist: true)
    }

    private var pendingDeleteIDs: Set<UUID> = []

    func stagePendingDelete(id: UUID) {
        pendingDeleteIDs.insert(id)
        rebuildOrdered()
    }

    func cancelPendingDelete(id: UUID) {
        pendingDeleteIDs.remove(id)
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
            if let target = e.payload.linkTargetID {
                inboundLinks[target, default: []].insert(e.atomID)
            }
        case .deleted:
            a.isDeleted = true
        }
        a.updatedAt = e.createdAt
        atoms[e.atomID] = a
        // Keep ordered in sync so stream rows see live snapshots without a full
        // rebuildOrdered(). rebuildOrdered() overwrites this when called (created/deleted).
        if let idx = ordered.firstIndex(where: { $0.id == e.atomID }) {
            ordered[idx] = a
        }
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
            .filter { !$0.isDeleted && !pendingDeleteIDs.contains($0.id) }
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
        let atomType = atoms[id]?.type ?? .thought
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await gemini.refine(raw: raw, type: atomType)
                // Type reveal: apply detected type FIRST so the dot/header bloom before
                // the content crossfade. Wrapped in spring animation for a visible pop.
                if let detected = result.type, detected != (atoms[id]?.type ?? atomType) {
                    let typeEv = NoteEvent(atomID: id, kind: .typeChanged, payload: .init(type: detected))
                    apply(typeEv, persist: true)
                }
                let ev = NoteEvent(atomID: id, kind: .refined, payload: .init(refinedContent: result.refined))
                apply(ev, persist: true)
                if !result.tags.isEmpty {
                    let tagEv = NoteEvent(atomID: id, kind: .tagged, payload: .init(tags: result.tags))
                    apply(tagEv, persist: true)
                }
            } catch {
                NousLogger.error("store", "startRefine failed", ["id": id.uuidString, "error": error.localizedDescription])
                let ev = NoteEvent(atomID: id, kind: .refined, payload: .init(refinedContent: ""))
                apply(ev, persist: true)
            }
        }
    }

    /// Manual type override from the detail view.
    func setType(id: UUID, to type: AtomType) {
        guard atoms[id]?.type != type else { return }
        let ev = NoteEvent(atomID: id, kind: .typeChanged, payload: .init(type: type))
        apply(ev, persist: true)
    }

    // MARK: - Link suggestions

    struct LinkSuggestion: Identifiable {
        let target: UUID
        let reason: String
        var id: UUID { target }
    }

    private(set) var linkSuggestions: [UUID: [LinkSuggestion]] = [:]

    func confirmSuggestion(for atomID: UUID, target: UUID) {
        let ev = NoteEvent(atomID: atomID, kind: .linked, payload: .init(linkTargetID: target, linkKind: "also-see"))
        apply(ev, persist: true)
        linkSuggestions[atomID]?.removeAll { $0.target == target }
    }

    func dismissSuggestion(for atomID: UUID, target: UUID) {
        linkSuggestions[atomID]?.removeAll { $0.target == target }
    }

    // MARK: - Stream grouping

    struct DayGroup: Identifiable {
        var id: Date { day }
        let day: Date
        let atoms: [AtomSnapshot]
        var mtgCount: Int { atoms.filter { $0.type == .meeting }.count }
    }

    func groupedByDay(filter: String? = nil, tag: String? = nil) -> [DayGroup] {
        let key = filter?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let tagKey = tag?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if let c = groupCache, c.filter == key, c.tag == tagKey, c.version == version { return c.value }

        let cal = Calendar.current
        var source = ordered
        if !key.isEmpty {
            source = source.filter { $0.displayContent.lowercased().contains(key) }
        }
        if !tagKey.isEmpty {
            source = source.filter { $0.tags.contains { $0.value.lowercased() == tagKey } }
        }
        let buckets = Dictionary(grouping: source) { cal.startOfDay(for: $0.createdAt) }
        let result = buckets.keys.sorted(by: >).map { DayGroup(day: $0, atoms: buckets[$0] ?? []) }
        groupCache = (key, tagKey, version, result)
        return result
    }

    /// Called by SyncDaemon when a remote event arrives (Chrome extension, web).
    /// Folds the event without persisting (already in SwiftData from pull()).
    func applyRemoteEvent(_ e: NoteEvent) {
        apply(e, persist: false)
        rebuildOrdered()
    }

    // Convenience
    var taskAtoms: [AtomSnapshot] { ordered.filter { $0.type == .task } }
    func inboundCount(of id: UUID) -> Int { inboundLinks[id]?.count ?? 0 }
}
