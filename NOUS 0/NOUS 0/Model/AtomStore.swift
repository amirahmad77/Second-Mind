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
    /// R1 — backend client for auto-link suggestions. Optional so existing call
    /// sites that don't pass one still compile; suggestions simply no-op when nil
    /// or when the backend URL is unset (mirrors PushbackVM's isConfiguredSync gate).
    private let backend: NousBackendClient?

    /// In-session refine failure counts. After maxRefineFailures, clear the shimmer for this
    /// session only (not persisted). Bootstrap re-queues on next launch when API is healthy.
    private var refineFailures: [UUID: Int] = [:]
    private static let maxRefineFailures = 3

    /// B1 — Out-of-order event guard. Keyed by "\(atomID)|\(group)" where group is the
    /// affected field family ("content"/"type"/"task"/"tags"/"due"). A stale remote event
    /// (clock skew, other device) older than the last applied event for the same group is
    /// skipped so it cannot silently revert newer state. `.linked` (additive) and `.deleted`
    /// (terminal) bypass this guard — they are monotonic and must always apply.
    private var lastApplied: [String: Date] = [:]

    /// B4 — Atoms the user intentionally reverted to raw (empty `.refined` sentinel).
    /// Populated when folding an empty `.refined` event, cleared when folding a non-empty
    /// one. Bootstrap's recovery pass must NOT re-queue refine for these.
    private var revertedAtoms: Set<UUID> = []

    init(context: ModelContext,
         sync: SyncDaemon,
         gemini: GeminiClient,
         backend: NousBackendClient? = nil) {
        self.context = context
        self.sync = sync
        self.gemini = gemini
        self.backend = backend
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
        // Recovery pass: atoms where a previous refine failure incorrectly wrote an empty
        // .refined event (isRefining=false, refinedContent=nil). Re-queue them now that
        // startRefine no longer writes the empty sentinel on failure.
        // B4 — exclude atoms the user intentionally reverted to raw. The empty `.refined`
        // sentinel is replayed during the fold above (populating revertedAtoms) BEFORE this
        // loop runs, so the revert stays sticky across relaunch.
        // R8 — skip this recovery pass when auto-refine is off: an atom captured with
        // refine disabled is intentionally unrefined, not an interrupted job. (The
        // isRefining-recovery loop above still runs — those atoms had refine in flight.)
        if Self.isAutoRefineEnabled {
            for atom in atoms.values where !atom.isRefining && !atom.isDeleted
                                        && atom.refinedContent == nil
                                        && atom.rawContent.count >= 8
                                        && !revertedAtoms.contains(atom.id) {
                startRefine(id: atom.id, raw: atom.rawContent)
            }
        }
        // Rewrite any pre-auth events to the signed-in user_id so they sync to
        // other devices. No-op if user not yet signed in or migration already ran.
        migrateLocalUserToSignedIn()
    }

    /// Rewrites `NoteEventRecord` rows stamped with the per-install `localUserID`
    /// to use the authenticated user's UUID, then marks them unsynced so drain()
    /// re-pushes them to Supabase under the correct `user_id`. Without this,
    /// atoms captured before sign-in are invisible on every other device forever.
    ///
    /// Idempotent: guarded by a UserDefaults key per (localID → authID) pair.
    func migrateLocalUserToSignedIn() {
        guard let authID = AuthClient.shared.session?.userID else { return }
        let localID = AppEnv.localUserID
        guard authID != localID else { return }
        // Guard: only migrate once per (localID, authID) pair.
        let migratedKey = "nous.sync.migrated.\(localID.uuidString).\(authID.uuidString)"
        guard !UserDefaults.standard.bool(forKey: migratedKey) else { return }
        let predicate = #Predicate<NoteEventRecord> { $0.userID == localID }
        let fetchDesc = FetchDescriptor<NoteEventRecord>(predicate: predicate)
        let records = (try? context.fetch(fetchDesc)) ?? []
        if !records.isEmpty {
            for rec in records {
                rec.userID = authID
                rec.synced = false   // force re-push under correct user_id
            }
            try? context.save()
            NousLogger.info("sync", "migrated pre-auth events to signed-in user",
                            ["count": "\(records.count)",
                             "from": localID.uuidString,
                             "to":   authID.uuidString])
        }
        UserDefaults.standard.set(true, forKey: migratedKey)
    }

    // MARK: - Public mutations

    /// Max capture size — guards against runaway paste (logs, binaries).
    /// Meeting transcripts can reach 200KB+ for 2-hour sessions; 256KB covers that.
    static let maxCaptureBytes = 256 * 1024

    /// R8 — auto-refine toggle (Settings). Missing key reads as TRUE (refine on by default).
    private static var isAutoRefineEnabled: Bool {
        let key = "nous.settings.autoRefine"
        return UserDefaults.standard.object(forKey: key) == nil
            || UserDefaults.standard.bool(forKey: key)
    }

    @discardableResult
    func capture(raw: String, type: AtomType = .thought) -> AtomSnapshot? {
        let normalized = Self.normalize(raw)
        guard !normalized.isEmpty else { return nil }
        let id = UUID()
        let ev = NoteEvent(atomID: id, kind: .created, payload: .init(content: normalized, type: type))
        apply(ev, persist: true)   // .created fold sets isRefining = true
        rebuildOrdered()
        if Self.isAutoRefineEnabled {
            startRefine(id: id, raw: normalized)
        } else {
            // Auto-refine off: clear the shimmer the .created fold set so the row
            // isn't stuck shimmering forever. The atom stays unrefined; the user
            // can trigger refine manually via refineNow(id:).
            clearRefiningFlag(id: id)
        }
        return atoms[id]
    }

    func updateRaw(id: UUID, newContent: String) {
        let normalized = Self.normalize(newContent)
        guard !normalized.isEmpty else { return }
        guard atoms[id]?.rawContent != normalized else { return }
        let ev = NoteEvent(atomID: id, kind: .updatedRaw, payload: .init(content: normalized))
        apply(ev, persist: true)   // .updatedRaw fold sets isRefining = true
        if Self.isAutoRefineEnabled {
            startRefine(id: id, raw: normalized)
        } else {
            clearRefiningFlag(id: id)
        }
    }

    /// R8 — public manual trigger for the Settings/atom "refine" button. Re-queues the
    /// Gemini refine job against the atom's current raw content regardless of the
    /// auto-refine setting. Restores the shimmer so the UI reflects in-flight work.
    func refineNow(id: UUID) {
        guard let a = atoms[id], !a.isDeleted else { return }
        refineFailures[id] = 0
        setRefiningFlag(id: id, refining: true)
        NousLogger.info("store", "manual refineNow", ["id": id.uuidString])
        startRefine(id: id, raw: a.rawContent)
    }

    /// Clears the transient `isRefining` shimmer in-memory (never persisted). Used when
    /// auto-refine is off so a freshly-captured atom doesn't shimmer indefinitely.
    private func clearRefiningFlag(id: UUID) {
        setRefiningFlag(id: id, refining: false)
    }

    private func setRefiningFlag(id: UUID, refining: Bool) {
        guard var a = atoms[id], a.isRefining != refining else { return }
        a.isRefining = refining
        atoms[id] = a
        if let idx = ordered.firstIndex(where: { $0.id == id }) {
            ordered[idx].isRefining = refining
        }
        version &+= 1
        groupCache = nil
    }

    private static func normalize(_ s: String) -> String {
        var out = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // Truncate by actual UTF-8 byte budget (not UTF-16/Character units, which
        // over-truncate CJK/emoji/RTL text). Repair any grapheme split at the cut.
        if out.utf8.count > maxCaptureBytes {
            let slice = Array(out.utf8.prefix(maxCaptureBytes))
            var truncated = String(decoding: slice, as: UTF8.self)
            // String(decoding:) replaces a split trailing scalar with U+FFFD; drop it.
            if truncated.unicodeScalars.last == "\u{FFFD}" { truncated.unicodeScalars.removeLast() }
            out = truncated + "…"
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
        // R3 — a completed task no longer needs its reminder.
        if done { ReminderScheduler.cancel(atomID: id) }
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
        // B6 — a checklist tick must NOT trigger a full re-refine. The displayed text comes
        // from `refinedContent ?? rawContent`, so write the edit back to whichever field is
        // the live source: if refined exists, emit a `.refined` event (sets isRefining=false,
        // updates refinedContent, no refine kicked off); otherwise edit raw via a path that
        // leaves isRefining untouched. Neither path calls startRefine().
        if a.refinedContent != nil {
            let ev = NoteEvent(atomID: id, kind: .refined, payload: .init(refinedContent: updated))
            apply(ev, persist: true)
        } else {
            applyRawEditNoRefine(id: id, content: updated)
        }
    }

    /// Folds a raw-content edit WITHOUT setting `isRefining` and WITHOUT triggering refine.
    /// Used by checklist toggles (B6): `.updatedRaw`'s normal fold sets isRefining=true, which
    /// would leave the row shimmering forever since no startRefine() follows a toggle.
    /// We reuse the `.updatedRaw` event (no new NoteEvent kind) but clear isRefining in the
    /// same synchronous flow after the fold.
    private func applyRawEditNoRefine(id: UUID, content: String) {
        let ev = NoteEvent(atomID: id, kind: .updatedRaw, payload: .init(content: content))
        apply(ev, persist: true)
        // The fold set isRefining=true; clear it (in-memory only — transient UI state,
        // never persisted). Skip if the event was guarded-out (atom missing/unchanged).
        guard var a = atoms[id], a.isRefining else { return }
        a.isRefining = false
        atoms[id] = a
        if let idx = ordered.firstIndex(where: { $0.id == id }) {
            ordered[idx].isRefining = false
        }
        version &+= 1
        groupCache = nil
    }

    func setDue(for id: UUID, days: Int) {
        let cal = Calendar.current
        let due = cal.startOfDay(for: cal.date(byAdding: .day, value: days, to: Date()) ?? Date())
        let ev = NoteEvent(atomID: id, kind: .dueSet, payload: .init(dueAt: due))
        apply(ev, persist: true)
        scheduleReminder(for: id, dueAt: due)   // R3
    }

    func setDue(id: UUID, to date: Date?) {
        let ev = NoteEvent(atomID: id, kind: .dueSet, payload: .init(dueAt: date))
        apply(ev, persist: true)
        scheduleReminder(for: id, dueAt: date)  // R3 — cancels when date == nil
    }

    /// R3 — schedule (or cancel) a local reminder for an atom's due date. Uses the
    /// atom's one-liner as the notification body. Authorization is requested lazily
    /// inside `ReminderScheduler.schedule` the first time a due date is set.
    private func scheduleReminder(for id: UUID, dueAt: Date?) {
        guard let dueAt else {
            ReminderScheduler.cancel(atomID: id)
            return
        }
        let body = atoms[id]?.oneLiner ?? ""
        Task { await ReminderScheduler.schedule(atomID: id, title: body, dueAt: dueAt) }
    }

    func delete(id: UUID) {
        let ev = NoteEvent(atomID: id, kind: .deleted, payload: .init())
        apply(ev, persist: true)
        rebuildOrdered()
        ReminderScheduler.cancel(atomID: id)   // R3
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

    // MARK: - Bulk mutations

    /// Bulk delete — applies a `.deleted` event per atom (same as single `delete`),
    /// cancels each atom's reminder, then rebuilds ordered once. Skips missing/
    /// already-deleted atoms so the count logged reflects real deletions.
    func bulkDelete(_ ids: [UUID]) {
        var deleted = 0
        for id in ids {
            guard let a = atoms[id], !a.isDeleted else { continue }
            let ev = NoteEvent(atomID: id, kind: .deleted, payload: .init())
            apply(ev, persist: true)
            ReminderScheduler.cancel(atomID: id)   // R3 — mirror single delete
            deleted += 1
        }
        rebuildOrdered()
        NousLogger.info("store", "bulk delete", ["requested": "\(ids.count)", "deleted": "\(deleted)"])
    }

    /// Bulk add a single tag to many atoms. Each atom reuses the single `addTag`
    /// path (dedupe + normalization + per-atom `.tagged` event), so atoms that
    /// already carry the tag are no-ops.
    func bulkAddTag(_ ids: [UUID], tag: String) {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return }
        for id in ids { addTag(id: id, tag: trimmed) }
        NousLogger.info("store", "bulk add tag", ["count": "\(ids.count)", "tag": trimmed])
    }

    /// Bulk set type. Reuses single `setType` (which no-ops when the type already
    /// matches), so a partially-matching selection only emits events where needed.
    func bulkSetType(_ ids: [UUID], to type: AtomType) {
        for id in ids { setType(id: id, to: type) }
        NousLogger.info("store", "bulk set type", ["count": "\(ids.count)", "type": type.rawValue])
    }

    /// Bulk set (or clear) due date. Reuses single `setDue(id:to:)`, which also
    /// schedules/cancels reminders. Passing `nil` clears the due date + reminder.
    func bulkSetDue(_ ids: [UUID], to date: Date?) {
        for id in ids { setDue(id: id, to: date) }
        NousLogger.info("store", "bulk set due",
                        ["count": "\(ids.count)", "due": date.map { "\($0)" } ?? "nil"])
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

    /// Field group an event mutates, for the B1 out-of-order guard.
    /// `nil` means the event is monotonic/terminal and bypasses the guard (always applies).
    private static func guardGroup(for kind: NoteEventKind) -> String? {
        switch kind {
        case .created, .updatedRaw, .refined: return "content"
        case .typeChanged:                     return "type"
        case .taskToggled:                     return "task"
        case .tagged:                          return "tags"
        case .dueSet:                          return "due"
        case .linked, .deleted:                return nil   // monotonic / terminal
        }
    }

    private func apply(_ e: NoteEvent, persist: Bool) {
        // B1 — out-of-order guard. For a guarded group, skip the fold entirely if this
        // event predates the last event already applied to the same group. A brand-new
        // atom (no stored timestamp) always applies. Bootstrap replays ascending, so the
        // first event of each group wins correctly.
        if let group = Self.guardGroup(for: e.kind) {
            let key = "\(e.atomID.uuidString)|\(group)"
            if let last = lastApplied[key], e.createdAt < last {
                // Stale event: the row is already persisted (local path) or already in
                // SwiftData (remote pull) — do not double-persist, just skip the mutation.
                return
            }
            lastApplied[key] = e.createdAt
        }

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
            a.refineFailed = false
        case .updatedRaw:
            a.rawContent = e.payload.content ?? a.rawContent
            a.isRefining = true
            a.refineFailed = false
        case .refined:
            let r = e.payload.refinedContent ?? ""
            a.refinedContent = r.isEmpty ? nil : r
            a.isRefining = false
            a.refineFailed = false
            // B4 — track intentional revert-to-raw (empty sentinel) vs real refine.
            if r.isEmpty { revertedAtoms.insert(e.atomID) }
            else         { revertedAtoms.remove(e.atomID) }
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
        // updatedAt only advances, never regresses on a late-but-not-stale event.
        a.updatedAt = max(a.updatedAt, e.createdAt)
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
        publishWidgetSnapshot()
    }

    /// Push a lightweight snapshot (recent atoms + open-task count) to the App
    /// Group so the home-screen widget can render. Cheap; WidgetKit throttles
    /// actual reloads.
    private func publishWidgetSnapshot() {
        let recent = ordered.prefix(5).map { atom in
            WidgetBridge.Snapshot.Item(
                id: atom.id.uuidString,
                line: atom.oneLiner,
                type: atom.type.rawValue,
                due: atom.type == .task ? atom.dueAt : nil
            )
        }
        let openTasks = ordered.filter { $0.type == .task && !($0.taskDone ?? false) }.count
        WidgetBridge.publish(recent: Array(recent), openTaskCount: openTasks)
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
                // R1 — refine succeeded; fetch auto-link suggestions in the background.
                // Uses the refined text (richer signal) so candidate matching is better.
                // Never blocks or fails refine — failures log and leave suggestions empty.
                self.fetchLinkSuggestions(for: id, text: result.refined)
                // Near-duplicate detection — runs after refine in a separate detached
                // task so it never extends the refine path or blocks the MainActor.
                // Depends on the atom's embedding existing; if it isn't cached yet the
                // pass simply finds nothing and can be re-run later from the detail view.
                Task { [weak self] in await self?.detectDuplicates(for: id) }
                // R9 — meeting → action-item tasks. The atom's effective type after this
                // refine is the detected type if present, else its pre-refine type.
                let finalType = result.type ?? (self.atoms[id]?.type ?? atomType)
                if finalType == .meeting {
                    self.extractMeetingActionItems(for: id, refined: result.refined)
                }
            } catch {
                NousLogger.error("store", "startRefine failed", ["id": id.uuidString, "error": error.localizedDescription])
                let failures = (self.refineFailures[id] ?? 0) + 1
                self.refineFailures[id] = failures
                if failures >= Self.maxRefineFailures {
                    // Clear the shimmer after repeated failures so the row is usable.
                    // Not persisted — bootstrap re-queues on next launch when API recovers.
                    NousLogger.warning("store", "clearing stuck refine after \(failures) failures", ["id": id.uuidString])
                    var a = self.atoms[id]
                    a?.isRefining = false
                    a?.refineFailed = true
                    if let a { self.atoms[a.id] = a }
                    if let idx = self.ordered.firstIndex(where: { $0.id == id }) {
                        self.ordered[idx].isRefining = false
                        self.ordered[idx].refineFailed = true
                    }
                    self.version &+= 1
                    self.groupCache = nil
                }
            }
        }
    }

    /// Manual retry after refine gave up (D2). Clears the failed flag in-memory, resets the
    /// in-session failure counter, restores the shimmer, and re-queues the Gemini job against
    /// the atom's current raw content. Transient state only — nothing persisted here; the
    /// eventual `.refined` fold (on success) persists as usual.
    func retryRefine(id: UUID) {
        guard var a = atoms[id], !a.isDeleted else { return }
        refineFailures[id] = 0
        a.refineFailed = false
        a.isRefining = true
        atoms[id] = a
        if let idx = ordered.firstIndex(where: { $0.id == id }) {
            ordered[idx].refineFailed = false
            ordered[idx].isRefining = true
        }
        version &+= 1
        groupCache = nil
        NousLogger.info("store", "manual refine retry", ["id": id.uuidString])
        startRefine(id: id, raw: a.rawContent)
    }

    // MARK: - R9 Meeting action items

    /// R9 — fire-and-forget extraction of action items from a refined meeting, creating
    /// a linked `.task` atom for each. Runs only when Gemini is reachable (resolvedKey
    /// gate inside `extractActionItems` makes it a clean no-op otherwise). Never blocks
    /// or fails refine — failures log and leave the meeting untouched.
    private func extractMeetingActionItems(for sourceID: UUID, refined: String) {
        let trimmed = refined.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            let items: [String]
            do {
                items = try await self.gemini.extractActionItems(from: trimmed)
            } catch {
                NousLogger.warning("store", "extractActionItems failed",
                                   ["id": sourceID.uuidString, "error": error.localizedDescription])
                return
            }
            guard !items.isEmpty else { return }
            // Guard against re-running on an atom that's been deleted while the call ran.
            guard self.atoms[sourceID]?.isDeleted == false else { return }
            for item in items {
                self.createLinkedTask(from: sourceID, text: item)
            }
            NousLogger.info("store", "meeting action items created",
                            ["source": sourceID.uuidString, "count": "\(items.count)"])
        }
    }

    /// R9 — creates a `.task` atom from an extracted action item and links it back to
    /// its source meeting. The task is built via events directly (`.created`) and
    /// `startRefine` is NEVER called for it, so a generated task cannot itself trigger
    /// another extraction pass — this is the loop-prevention guarantee. The `.created`
    /// fold sets isRefining=true, so we immediately clear the shimmer (no refine follows).
    func createLinkedTask(from sourceID: UUID, text: String) {
        let normalized = Self.normalize(text)
        guard !normalized.isEmpty else { return }
        let taskID = UUID()
        // Create the task atom WITHOUT triggering refine (loop prevention).
        let createEv = NoteEvent(atomID: taskID, kind: .created,
                                 payload: .init(content: normalized, type: .task))
        apply(createEv, persist: true)
        // The .created fold set isRefining=true; clear it (no refine job is queued).
        clearRefiningFlag(id: taskID)
        // Link source meeting → new task.
        let linkEv = NoteEvent(atomID: sourceID, kind: .linked,
                               payload: .init(linkTargetID: taskID, linkKind: "action-item"))
        apply(linkEv, persist: true)
        rebuildOrdered()
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

    /// R1 — fetch backend link suggestions for an atom and populate `linkSuggestions`.
    /// Fire-and-forget; runs after a successful refine. Filters self-links, already
    /// linked targets (confirmed inbound graph), and deleted atoms. No-ops when the
    /// backend is unset (mirrors PushbackVM's `isConfiguredSync` gate).
    private func fetchLinkSuggestions(for atomID: UUID, text: String) {
        guard let backend, backend.isConfiguredSync else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            let userID = await AppEnv.currentUserID()
            do {
                let resp = try await backend.suggestLinks(userID: userID,
                                                          atomID: atomID,
                                                          text: trimmed)
                self.applyLinkSuggestions(resp, for: atomID)
            } catch {
                NousLogger.warning("store", "suggestLinks failed",
                                   ["id": atomID.uuidString, "error": error.localizedDescription])
            }
        }
    }

    /// Maps a backend response → `[LinkSuggestion]` and stores it, filtering invalid
    /// targets. Runs on the MainActor (AtomStore isolation) so reading `atoms` /
    /// `inboundLinks` is safe.
    private func applyLinkSuggestions(_ resp: NousBackendClient.SuggestLinksResponse,
                                      for atomID: UUID) {
        // Targets this atom already links to: inboundLinks[target] holds the set of
        // SOURCE ids linking to `target`, so any key whose set contains `atomID` is a
        // target `atomID` already points at. Exclude those (no duplicate suggestions).
        let alreadyLinkedTargets = Set(
            inboundLinks.filter { $0.value.contains(atomID) }.keys
        )

        let mapped: [LinkSuggestion] = resp.suggestions.compactMap { s in
            let target = s.atom_id
            guard target != atomID else { return nil }              // no self-links
            guard atoms[target]?.isDeleted == false else { return nil } // skip deleted/missing
            guard !alreadyLinkedTargets.contains(target) else { return nil } // skip existing
            return LinkSuggestion(target: target, reason: s.reason)
        }
        // Dedupe by target, preserving backend ordering (highest score first).
        var seen = Set<UUID>()
        let deduped = mapped.filter { seen.insert($0.target).inserted }
        guard !deduped.isEmpty else {
            linkSuggestions[atomID] = []
            return
        }
        linkSuggestions[atomID] = deduped
        NousLogger.info("store", "link suggestions populated",
                        ["id": atomID.uuidString, "count": "\(deduped.count)"])
    }

    func confirmSuggestion(for atomID: UUID, target: UUID) {
        let ev = NoteEvent(atomID: atomID, kind: .linked, payload: .init(linkTargetID: target, linkKind: "also-see"))
        apply(ev, persist: true)
        linkSuggestions[atomID]?.removeAll { $0.target == target }
    }

    func dismissSuggestion(for atomID: UUID, target: UUID) {
        linkSuggestions[atomID]?.removeAll { $0.target == target }
    }

    // MARK: - Near-duplicate detection

    /// Cosine similarity at/above which two atoms are treated as near-duplicates.
    /// Deliberately high (0.90) — link suggestions use 0.55 for "related"; duplicates
    /// must be essentially the same thought to avoid noisy false positives.
    private static let duplicateThreshold: Float = 0.90
    /// Cap on candidate vectors scanned per detection pass. Keeps the off-main
    /// compute cheap on large stores; newest atoms are the likeliest dup sources.
    private static let duplicateCandidateCap = 400
    /// Max near-duplicate suggestions surfaced per atom.
    private static let maxDuplicateSuggestions = 3

    /// atom → near-duplicate atom ids (highest similarity first). Populated by
    /// `detectDuplicates(for:)` after a refine completes. Transient (never persisted);
    /// rebuilt on demand. Empty / missing entry means "no duplicates known".
    private(set) var duplicateSuggestions: [UUID: [UUID]] = [:]

    /// Atom pairs the user has explicitly dismissed as not-duplicates, so a later
    /// re-detection doesn't resurface them. Keyed by the unordered pair (both
    /// directions inserted) "\(a)|\(b)". Transient — session-scoped, mirrors the
    /// in-memory nature of the suggestions themselves.
    private var dismissedDuplicatePairs: Set<String> = []

    private static func duplicatePairKey(_ a: UUID, _ b: UUID) -> String {
        a.uuidString < b.uuidString ? "\(a.uuidString)|\(b.uuidString)"
                                    : "\(b.uuidString)|\(a.uuidString)"
    }

    /// Detects near-duplicate atoms of `id` by cosine similarity over cached
    /// embeddings, then populates `duplicateSuggestions[id]`.
    ///
    /// Mirrors `RelatedFinder`: the MainActor only fetches `EmbeddingRecord`s and
    /// builds Sendable value snapshots (`[Float]` + `[(UUID, [Float])]`); the
    /// O(n·dim) cosine math runs in a detached task so it never blocks the MainActor.
    /// `EmbeddingRecord` (a SwiftData `@Model`) and `AtomStore` never cross the
    /// actor boundary.
    ///
    /// Cheap by construction: candidates are capped, deleted/already-linked atoms
    /// and user-dismissed pairs are excluded. Safe to call repeatedly. Never throws,
    /// never blocks refine — failures leave the existing suggestions untouched.
    func detectDuplicates(for id: UUID) async {
        guard let source = atoms[id], !source.isDeleted else { return }

        let descriptor = FetchDescriptor<EmbeddingRecord>()
        let allRecords = (try? context.fetch(descriptor)) ?? []
        guard let sourceRecord = allRecords.first(where: { $0.atomID == id }) else { return }
        let sourceVec = sourceRecord.toFloatArray()
        guard !sourceVec.isEmpty else { return }

        // Targets `id` already links to: inboundLinks[target] holds the SOURCE ids
        // linking to `target`, so any key whose set contains `id` is already linked.
        let alreadyLinkedTargets = Set(inboundLinks.filter { $0.value.contains(id) }.keys)

        // Build a Sendable candidate snapshot on the MainActor. Newest-first so the
        // cap keeps the most likely duplicate sources. Excludes self, deleted/missing
        // atoms, already-linked targets, and user-dismissed pairs.
        let candidates: [(UUID, [Float])] = allRecords
            .compactMap { record -> (UUID, [Float], Date)? in
                let other = record.atomID
                guard other != id,
                      let atom = atoms[other], !atom.isDeleted,
                      !alreadyLinkedTargets.contains(other),
                      !dismissedDuplicatePairs.contains(Self.duplicatePairKey(id, other))
                else { return nil }
                return (other, record.toFloatArray(), atom.createdAt)
            }
            .sorted { $0.2 > $1.2 }
            .prefix(Self.duplicateCandidateCap)
            .map { ($0.0, $0.1) }

        guard !candidates.isEmpty else {
            duplicateSuggestions[id] = []
            return
        }

        let threshold = Self.duplicateThreshold
        let maxResults = Self.maxDuplicateSuggestions
        let matchedIDs: [UUID] = await Task.detached(priority: .utility) {
            candidates
                .compactMap { candidate -> (UUID, Float)? in
                    let (uuid, vec) = candidate
                    guard vec.count == sourceVec.count else { return nil }
                    let sim = RelatedFinder.cosineSimilarity(sourceVec, vec)
                    return sim >= threshold ? (uuid, sim) : nil
                }
                .sorted { $0.1 > $1.1 }
                .prefix(maxResults)
                .map(\.0)
        }.value

        // Back on the MainActor: re-validate (atoms may have changed during compute).
        let valid = matchedIDs.filter { atoms[$0]?.isDeleted == false }
        duplicateSuggestions[id] = valid
        if !valid.isEmpty {
            NousLogger.info("store", "near-duplicates detected",
                            ["id": id.uuidString, "count": "\(valid.count)"])
        }
    }

    /// Removes a single near-duplicate suggestion and remembers the pair as dismissed
    /// so re-detection won't resurface it this session.
    func dismissDuplicate(for id: UUID, other: UUID) {
        dismissedDuplicatePairs.insert(Self.duplicatePairKey(id, other))
        duplicateSuggestions[id]?.removeAll { $0 == other }
        NousLogger.info("store", "near-duplicate dismissed",
                        ["id": id.uuidString, "other": other.uuidString])
    }

    /// Conservatively merges two near-duplicate atoms, keeping `keep` and soft-deleting
    /// `drop`. Reversible-ish: `drop` is soft-deleted (a `.deleted` event), never hard
    /// removed, so its history survives in the ledger.
    ///
    /// Steps (all event-sourced):
    ///   1. Append `drop`'s display content to `keep`'s raw content as a new
    ///      `.updatedRaw` event (so the merged text re-refines naturally).
    ///   2. Write a `.linked` from `keep` → `drop` for provenance.
    ///   3. Soft-`delete(id: drop)`.
    ///
    /// Loop-safe: no-ops on invalid input (missing atom, same id, already-deleted),
    /// and clears any cross-suggestions between the pair so the banner can't re-fire.
    func mergeDuplicate(keep: UUID, drop: UUID) {
        guard keep != drop else { return }
        guard let keepAtom = atoms[keep], !keepAtom.isDeleted else { return }
        guard let dropAtom = atoms[drop], !dropAtom.isDeleted else { return }

        // 1. Append the dropped atom's content to the kept atom's raw text. The
        //    `.updatedRaw` fold sets isRefining=true and (when auto-refine is on)
        //    re-refines the combined text. updateRaw normalizes + dedupes no-ops.
        let dropText = dropAtom.displayContent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !dropText.isEmpty {
            let merged = keepAtom.rawContent + "\n\n---\n\n" + dropText
            updateRaw(id: keep, newContent: merged)
        }

        // 2. Provenance link keep → drop (the dropped atom remains reachable).
        let linkEv = NoteEvent(atomID: keep, kind: .linked,
                               payload: .init(linkTargetID: drop, linkKind: "merged-duplicate"))
        apply(linkEv, persist: true)

        // 3. Soft-delete the dropped atom.
        delete(id: drop)

        // Clear any suggestions between the pair so the UI can't re-offer the merge.
        duplicateSuggestions[keep]?.removeAll { $0 == drop }
        duplicateSuggestions[drop] = []
        dismissedDuplicatePairs.insert(Self.duplicatePairKey(keep, drop))

        NousLogger.info("store", "near-duplicates merged",
                        ["keep": keep.uuidString, "drop": drop.uuidString])
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

    /// Read-only edge list for the constellation graph. `inboundLinks` maps a
    /// target → the set of source ids that link to it; this flattens it into
    /// directed (source → target) pairs. Only edges where BOTH endpoints exist
    /// and are not soft-deleted are returned, so the graph never draws a line to
    /// a vanished node. Keeps `inboundLinks` private — the graph reads positions
    /// off ids it already has from `ordered`.
    var linkEdges: [(source: UUID, target: UUID)] {
        inboundLinks.flatMap { target, sources -> [(source: UUID, target: UUID)] in
            guard atoms[target]?.isDeleted == false else { return [] }
            return sources.compactMap { source in
                guard atoms[source]?.isDeleted == false else { return nil }
                return (source: source, target: target)
            }
        }
    }

    func inboundCount(of id: UUID) -> Int { inboundLinks[id]?.count ?? 0 }
    func inboundAtoms(for id: UUID) -> [AtomSnapshot] {
        guard let sources = inboundLinks[id] else { return [] }
        return sources.compactMap { atoms[$0] }.filter { !$0.isDeleted }
    }
}
