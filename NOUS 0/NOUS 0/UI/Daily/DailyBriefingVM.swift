import Foundation
import Observation

// ─── DailyBriefingVM ────────────────────────────────────────────────────────
//
// Aggregates the day's signal from the AtomStore (and, when configured, the
// NOUS backend) into a small set of editorial "briefing" sections.
//
// Resilience contract:
//   - Every section is computed independently. A failure or empty result in one
//     never affects the others.
//   - Backend-derived sections (Pushback) degrade gracefully: when the backend
//     URL is unset (mirrors PushbackVM.isConfiguredSync / AtomStore's gate) the
//     section is simply omitted. Nothing crashes when the backend is nil.
//   - refresh() is safe to call repeatedly; it rebuilds from the live store
//     snapshot each time.
//
// Data sources (file:line at time of writing):
//   - Due / overdue tasks  → AtomStore.taskAtoms (AtomStore.swift:565) filtered
//     by AtomSnapshot.dueAt (Atom.swift:38) + taskDone (Atom.swift:37).
//   - On this day          → DailyDigest.compute (DailyDigest.swift:21) → .onThisDay.
//   - Resurfaced           → ProactiveSurface scoring logic (ProactiveSurface.swift:107)
//     replicated here (the original picker is private), over AtomStore.ordered
//     (AtomStore.swift:11) + AtomStore.inboundCount (AtomStore.swift:566).
//   - Pushback             → PushbackVM.visibleItems (PushbackVM.swift:23),
//     backed by NousBackendClient.PushbackItem (NousBackendClient.swift:236).

@Observable
@MainActor
final class DailyBriefingVM {

    // MARK: - Section model

    enum SectionKind: String {
        case dueTasks
        case onThisDay
        case resurfaced
        case pushback
    }

    /// One row inside a section. Most rows wrap an atom; pushback rows carry a
    /// prompt string and an optional anchor atom to open.
    struct BriefingItem: Identifiable, Hashable {
        let id: String
        /// The atom this row opens, when tappable. `nil` for prompt-only rows.
        let atom: AtomSnapshot?
        /// One-line headline shown in the row.
        let headline: String
        /// Optional trailing meta (e.g. "overdue 3d", "2y ago", "thread").
        let meta: String?
    }

    struct BriefingSection: Identifiable {
        let kind: SectionKind
        let title: String
        /// SF Symbol for the section header glyph.
        let systemImage: String
        /// Phosphor accent for the section dot / glyph.
        let phosphor: PhosphorAccent
        let items: [BriefingItem]
        var id: String { kind.rawValue }
    }

    /// Maps to NSColorToken.Phos.* in the view layer. Kept as a plain enum here so
    /// the VM stays free of SwiftUI/Color (Color access is @MainActor + view-side).
    enum PhosphorAccent {
        case cyan, green, amber, blue, orange, violet
    }

    // MARK: - State

    private(set) var sections: [BriefingSection] = []
    /// Best-effort timestamp of the last successful aggregation.
    private(set) var lastRefreshed: Date?

    // MARK: - Dependencies

    private let store: AtomStore
    /// Optional. When nil (or backend unset) the Pushback section is omitted.
    private let pushback: PushbackVM?

    /// Resurfacing tuning — mirrors ProactiveSurface constants.
    private static let staleAfterDays = 42       // 6 weeks
    /// Cap on rows surfaced per section so the briefing stays scannable.
    private static let maxRowsPerSection = 6

    init(store: AtomStore, pushback: PushbackVM? = nil) {
        self.store = store
        self.pushback = pushback
    }

    // MARK: - Refresh

    /// Rebuilds every section from the current store (+ backend) snapshot.
    /// Each section is wrapped so a thrown/empty section never breaks the rest.
    func refresh(now: Date = .now) {
        // Kick a fresh backend pushback fetch when available — fire-and-forget;
        // its results land on a later refresh() via PushbackVM's @Observable state.
        pushback?.refresh()

        var built: [BriefingSection] = []
        if let s = dueSection(now: now)        { built.append(s) }
        if let s = onThisDaySection(now: now)  { built.append(s) }
        if let s = resurfacedSection(now: now) { built.append(s) }
        if let s = pushbackSection()           { built.append(s) }

        sections = built
        lastRefreshed = now
        NousLogger.info("store", "daily briefing rebuilt",
                        ["sections": "\(built.count)",
                         "rows": "\(built.reduce(0) { $0 + $1.items.count })"])
    }

    // MARK: - Section: Due / overdue tasks

    /// Open tasks whose `dueAt` is in the past (overdue) or lands today.
    /// Overdue first, then today; each sorted by how pressing it is.
    private func dueSection(now: Date) -> BriefingSection? {
        let cal = Calendar.current
        let endOfToday = cal.date(byAdding: .day, value: 1,
                                  to: cal.startOfDay(for: now)) ?? now

        let open = store.taskAtoms.filter { atom in
            guard !atom.isDeleted, !(atom.taskDone ?? false) else { return false }
            guard let due = atom.dueAt else { return false }
            return due < endOfToday   // overdue OR due today
        }
        guard !open.isEmpty else { return nil }

        // Most overdue first (earliest due date first).
        let sorted = open.sorted { ($0.dueAt ?? now) < ($1.dueAt ?? now) }
        let items = sorted.prefix(Self.maxRowsPerSection).map { atom -> BriefingItem in
            BriefingItem(id: "due-\(atom.id.uuidString)",
                         atom: atom,
                         headline: atom.oneLiner,
                         meta: dueMeta(for: atom.dueAt, now: now, calendar: cal))
        }
        return BriefingSection(kind: .dueTasks,
                               title: "due",
                               systemImage: "checkmark.circle",
                               phosphor: .green,
                               items: Array(items))
    }

    private func dueMeta(for due: Date?, now: Date, calendar: Calendar) -> String? {
        guard let due else { return nil }
        let startToday = calendar.startOfDay(for: now)
        let startDue   = calendar.startOfDay(for: due)
        let days = calendar.dateComponents([.day], from: startDue, to: startToday).day ?? 0
        if days > 0 { return "overdue \(days)d" }
        if days == 0 { return "today" }
        return nil
    }

    // MARK: - Section: On this day

    /// Reuses DailyDigest's "on this day" picker (atom from a prior year, same
    /// calendar day). Single best pick — the strongest memory hook.
    private func onThisDaySection(now: Date) -> BriefingSection? {
        let picks = DailyDigest.compute(from: store.ordered, now: now)
        guard let atom = picks.onThisDay else { return nil }
        let years = max(1, Calendar.current
            .dateComponents([.year], from: atom.createdAt, to: now).year ?? 1)
        let item = BriefingItem(id: "otd-\(atom.id.uuidString)",
                                atom: atom,
                                headline: atom.oneLiner,
                                meta: "\(years)y ago")
        return BriefingSection(kind: .onThisDay,
                               title: "on this day",
                               systemImage: "calendar",
                               phosphor: .violet,
                               items: [item])
    }

    // MARK: - Section: Resurfaced

    /// A stale-but-anchored atom worth a second look. Replicates ProactiveSurface's
    /// scoring (inbound-link weight × log-scaled age) deterministically — picks the
    /// single top-scored stale atom rather than a random sample, so the briefing is
    /// stable through a session.
    private func resurfacedSection(now: Date) -> BriefingSection? {
        let staleSeconds = TimeInterval(Self.staleAfterDays) * 86_400
        let pool = store.ordered.filter { atom in
            guard !atom.isDeleted else { return false }
            return now.timeIntervalSince(atom.updatedAt) >= staleSeconds
        }
        guard !pool.isEmpty else { return nil }

        // Prefer anchored (inbound-linked) stale atoms — they carry more signal.
        let scored = pool.map { atom -> (atom: AtomSnapshot, score: Double) in
            let inbound = Double(store.inboundCount(of: atom.id))
            let weeks = now.timeIntervalSince(atom.updatedAt) / (86_400 * 7)
            let score = (1.0 + inbound) * log2(2 + weeks)
            return (atom, score)
        }
        guard let best = scored.max(by: { $0.score < $1.score })?.atom else { return nil }

        let weeks = Int(now.timeIntervalSince(best.updatedAt) / (86_400 * 7))
        let inbound = store.inboundCount(of: best.id)
        var meta = "\(max(1, weeks))w ago"
        if inbound > 0 { meta += " · \(inbound) link\(inbound == 1 ? "" : "s")" }

        let item = BriefingItem(id: "resurfaced-\(best.id.uuidString)",
                                atom: best,
                                headline: best.oneLiner,
                                meta: meta)
        return BriefingSection(kind: .resurfaced,
                               title: "resurfaced",
                               systemImage: "arrow.uturn.backward",
                               phosphor: .amber,
                               items: [item])
    }

    // MARK: - Section: Pushback

    /// Backend epistemic-pushback prompts, when a configured PushbackVM is present.
    /// Omitted entirely when no backend / no visible items — never blocks or crashes.
    private func pushbackSection() -> BriefingSection? {
        guard let pushback else { return nil }
        let visible = pushback.visibleItems
        guard !visible.isEmpty else { return nil }

        let items = visible.prefix(Self.maxRowsPerSection).map { p -> BriefingItem in
            // Anchor to the first referenced atom (if it still exists) so the row
            // is tappable; otherwise prompt-only.
            let anchor = p.atom_ids.first.flatMap { store.atoms[$0] }
            return BriefingItem(id: "pushback-\(p.id)",
                                atom: anchor?.isDeleted == false ? anchor : nil,
                                headline: p.prompt,
                                meta: p.kind)
        }
        return BriefingSection(kind: .pushback,
                               title: "pushback",
                               systemImage: "exclamationmark.bubble",
                               phosphor: .orange,
                               items: Array(items))
    }
}
