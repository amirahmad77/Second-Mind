#if os(macOS)
import SwiftUI

// ─── MacCommandPalette ─────────────────────────────────────────────────────────
//
// Raycast / Linear-style ⌘K palette. A centered overlay panel over a blurred
// scrim. Two result kinds:
//
//   1. Atoms    — substring/token match over store.ordered (oneLiner + tags),
//                 ranked by match quality then recency. Selecting opens the atom.
//   2. Commands — static actions (New Capture, Search, Synthesis, Compose,
//                 Record Meeting) + type filters (thoughts/tasks/meetings/…).
//                 Selecting runs the action.
//
// Keyboard:
//   ↑ / ↓   move selection
//   ↩       activate highlighted result
//   Esc     dismiss
//
// Self-contained: the host (MacRootView) presents it as an overlay gated by a
// @State bound to .nousOpenPalette and supplies an `actions` struct mapping each
// command back to the exact path the toolbar buttons already use.

// MARK: – Notification

extension Notification.Name {
    /// Posted by the ⌘K menu command in NOUS_0App; observed in MacRootView.
    static let nousOpenPalette = Notification.Name("nous.openPalette")
}

// MARK: – Command kind

/// Static (non-atom) palette actions. Raw mapping to host behaviour lives in
/// `MacCommandPalette.Actions`, so the palette stays free of app wiring.
enum MacPaletteCommand: Hashable, CaseIterable {
    case newCapture
    case search
    case synthesis
    case compose
    case recordMeeting
    case filterThoughts
    case filterTasks
    case filterMeetings
    case filterDecisions
    case filterQuestions
    case filterReferences

    var title: String {
        switch self {
        case .newCapture:       "New Capture"
        case .search:           "Search"
        case .synthesis:        "Synthesize"
        case .compose:          "Compose"
        case .recordMeeting:    "Record Meeting"
        case .filterThoughts:   "Filter: thoughts"
        case .filterTasks:      "Filter: tasks"
        case .filterMeetings:   "Filter: meetings"
        case .filterDecisions:  "Filter: decisions"
        case .filterQuestions:  "Filter: questions"
        case .filterReferences: "Filter: references"
        }
    }

    var systemImage: String {
        switch self {
        case .newCapture:    "plus"
        case .search:        "magnifyingglass"
        case .synthesis:     "sparkles"
        case .compose:       "pencil.and.scribble"
        case .recordMeeting: "mic.circle"
        default:             "line.3.horizontal.decrease.circle"
        }
    }

    /// Keywords the searcher matches against in addition to the title.
    var keywords: String {
        switch self {
        case .newCapture:       "new capture note thought add ⌘n"
        case .search:           "search find query"
        case .synthesis:        "synthesize synthesis ask question sparkles"
        case .compose:          "compose write draft"
        case .recordMeeting:    "record meeting mic transcript"
        case .filterThoughts:   "filter thoughts thought"
        case .filterTasks:      "filter tasks task todo"
        case .filterMeetings:   "filter meetings meeting"
        case .filterDecisions:  "filter decisions decision"
        case .filterQuestions:  "filter questions question"
        case .filterReferences: "filter references reference link"
        }
    }

    /// Phosphor dot for type-filter commands (nil for plain actions).
    @MainActor var phosphor: Color? {
        switch self {
        case .filterThoughts:   AtomType.thought.phosphor
        case .filterTasks:      AtomType.task.phosphor
        case .filterMeetings:   AtomType.meeting.phosphor
        case .filterDecisions:  AtomType.decision.phosphor
        case .filterQuestions:  AtomType.question.phosphor
        case .filterReferences: AtomType.reference.phosphor
        default:                nil
        }
    }
}

// MARK: – Result row model

private enum PaletteResult: Identifiable, Hashable {
    case command(MacPaletteCommand)
    case atom(AtomSnapshot)

    var id: String {
        switch self {
        case .command(let c): "cmd-\(c)"
        case .atom(let a):    "atom-\(a.id.uuidString)"
        }
    }
}

// MARK: – Palette view

struct MacCommandPalette: View {

    /// Host-supplied action closures. Each maps a command back to the exact
    /// behaviour the toolbar buttons already trigger (no new mechanisms).
    struct Actions {
        let openCapture:   () -> Void
        let openSearch:    () -> Void
        let openSynthesis: () -> Void
        let openCompose:   () -> Void
        let recordMeeting: () -> Void
        let setTypeFilter: (AtomType) -> Void
        let openAtom:      (AtomSnapshot) -> Void
    }

    let store:   AtomStore
    let actions: Actions
    /// Dismiss the palette (clears the host's `showPalette` flag).
    let onClose: () -> Void

    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var fieldFocused: Bool

    private let maxResults = 30

    // MARK: Body

    var body: some View {
        ZStack {
            // Blurred scrim — tap to dismiss.
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(NSColorToken.inkVoid.opacity(0.35))
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onClose() }

            panel
                .frame(width: 560)
                .frame(maxHeight: 460)
        }
        .transition(.opacity)
        .onAppear { fieldFocused = true }
        // Reset highlight whenever the result set changes.
        .onChange(of: query) { _, _ in selectedIndex = 0 }
    }

    // MARK: Panel

    private var panel: some View {
        VStack(spacing: 0) {
            searchField
            Divider().overlay(NSColorToken.textGhost.opacity(0.12))
            resultsList
        }
        .background(NSColorToken.inkPaper)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(NSColorToken.textGhost.opacity(0.18), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.5), radius: 28, x: 0, y: 12)
    }

    // MARK: Search field

    private var searchField: some View {
        HStack(spacing: NSpace.md) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(NSColorToken.Phos.cyan.opacity(0.8))

            // Hidden keyboard handlers — arrows / return / esc.
            // Placed behind the field so they don't steal focus.
            ZStack {
                keyHandlers
                TextField("// type a command or search atoms…", text: $query)
                    .textFieldStyle(.plain)
                    .font(NFont.mono(15))
                    .foregroundStyle(NSColorToken.textPrimary)
                    .focused($fieldFocused)
                    .onSubmit { activateSelection() }
            }
        }
        .padding(.horizontal, NSpace.lg)
        .padding(.vertical, NSpace.md)
    }

    /// Invisible buttons that own the ↑/↓/Esc shortcuts while the field has focus.
    private var keyHandlers: some View {
        ZStack {
            Button("") { moveSelection(-1) }
                .keyboardShortcut(.upArrow, modifiers: [])
            Button("") { moveSelection(1) }
                .keyboardShortcut(.downArrow, modifiers: [])
            Button("") { onClose() }
                .keyboardShortcut(.escape, modifiers: [])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    // MARK: Results

    private var resultsList: some View {
        let results = computeResults()
        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if results.isEmpty {
                        Text("// no matches")
                            .font(NFont.mono(11))
                            .foregroundStyle(NSColorToken.textGhost.opacity(0.5))
                            .padding(.horizontal, NSpace.lg)
                            .padding(.vertical, NSpace.md)
                    } else {
                        ForEach(Array(results.enumerated()), id: \.element.id) { idx, result in
                            rowView(result, isSelected: idx == selectedIndex)
                                .id(idx)
                                .contentShape(Rectangle())
                                .onTapGesture { activate(result) }
                        }
                    }
                }
                .padding(.vertical, NSpace.sm)
            }
            .frame(maxHeight: 380)
            .onChange(of: selectedIndex) { _, idx in
                withAnimation(.nEaseOutQuint) { proxy.scrollTo(idx, anchor: .center) }
            }
        }
    }

    @ViewBuilder
    private func rowView(_ result: PaletteResult, isSelected: Bool) -> some View {
        HStack(spacing: NSpace.md) {
            switch result {
            case .command(let cmd):
                if let phos = cmd.phosphor {
                    Circle().fill(phos).frame(width: 7, height: 7)
                } else {
                    Image(systemName: cmd.systemImage)
                        .font(.system(size: 11))
                        .foregroundStyle(NSColorToken.textTertiary)
                        .frame(width: 14)
                }
                Text(cmd.title)
                    .font(NFont.mono(13))
                    .foregroundStyle(isSelected ? NSColorToken.textPrimary : NSColorToken.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("// action")
                    .font(NFont.monoSmall(9))
                    .foregroundStyle(NSColorToken.textGhost.opacity(0.45))

            case .atom(let atom):
                Circle()
                    .fill(atom.type.phosphor)
                    .frame(width: 7, height: 7)
                    .shadow(color: atom.type.phosphor.opacity(0.35), radius: 3)
                Text(atom.oneLiner)
                    .font(NFont.mono(13))
                    .foregroundStyle(isSelected ? NSColorToken.textPrimary : NSColorToken.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: NSpace.sm)
                Text(relativeDate(atom.createdAt))
                    .font(NFont.monoSmall(9))
                    .foregroundStyle(NSColorToken.textGhost.opacity(0.6))
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, NSpace.lg)
        .padding(.vertical, NSpace.sm)
        .background(
            isSelected ? NSColorToken.inkRaised.opacity(0.7) : Color.clear
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, NSpace.xs)
        .animation(.nPress, value: isSelected)
    }

    // MARK: Search / ranking

    /// Builds the ranked result list. Commands appear first when the query is
    /// empty or matches; atoms are ranked by match quality then recency. Capped
    /// at `maxResults`.
    private func computeResults() -> [PaletteResult] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // Commands
        let commands: [MacPaletteCommand]
        if q.isEmpty {
            commands = MacPaletteCommand.allCases
        } else {
            commands = MacPaletteCommand.allCases.filter { cmd in
                let hay = (cmd.title + " " + cmd.keywords).lowercased()
                return hay.contains(q)
            }
        }

        // Atoms
        let atomResults: [(atom: AtomSnapshot, rank: Int)]
        if q.isEmpty {
            // No query: surface most recent atoms only (commands lead).
            atomResults = store.ordered
                .filter { !$0.isDeleted }
                .prefix(maxResults)
                .map { ($0, 0) }
        } else {
            atomResults = store.ordered
                .filter { !$0.isDeleted }
                .compactMap { atom in
                    guard let r = matchRank(atom: atom, query: q) else { return nil }
                    return (atom, r)
                }
                // Lower rank = better; tiebreak by recency (createdAt desc).
                .sorted { lhs, rhs in
                    if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
                    return lhs.atom.createdAt > rhs.atom.createdAt
                }
        }

        var out: [PaletteResult] = commands.map { .command($0) }
        out += atomResults.map { .atom($0.atom) }
        return Array(out.prefix(maxResults))
    }

    /// Returns a rank for an atom against the query, or nil if no match.
    /// 0 = prefix match on one-liner, 1 = substring in one-liner, 2 = tag match.
    @MainActor
    private func matchRank(atom: AtomSnapshot, query q: String) -> Int? {
        let line = atom.oneLiner.lowercased()
        if line.hasPrefix(q) { return 0 }
        if line.contains(q)  { return 1 }
        if atom.tags.contains(where: { $0.value.lowercased().contains(q) }) { return 2 }
        return nil
    }

    private func relativeDate(_ date: Date) -> String {
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .abbreviated
        return fmt.localizedString(for: date, relativeTo: Date())
    }

    // MARK: Keyboard actions

    private func moveSelection(_ delta: Int) {
        let count = computeResults().count
        guard count > 0 else { return }
        selectedIndex = max(0, min(count - 1, selectedIndex + delta))
    }

    private func activateSelection() {
        let results = computeResults()
        guard results.indices.contains(selectedIndex) else { return }
        activate(results[selectedIndex])
    }

    private func activate(_ result: PaletteResult) {
        switch result {
        case .atom(let atom):
            NousLogger.info("palette", "open atom", ["id": atom.id.uuidString])
            actions.openAtom(atom)
        case .command(let cmd):
            NousLogger.info("palette", "run command", ["cmd": "\(cmd)"])
            run(cmd)
        }
        onClose()
    }

    /// Maps each command to the host action closure (same path toolbar uses).
    private func run(_ cmd: MacPaletteCommand) {
        switch cmd {
        case .newCapture:       actions.openCapture()
        case .search:           actions.openSearch()
        case .synthesis:        actions.openSynthesis()
        case .compose:          actions.openCompose()
        case .recordMeeting:    actions.recordMeeting()
        case .filterThoughts:   actions.setTypeFilter(.thought)
        case .filterTasks:      actions.setTypeFilter(.task)
        case .filterMeetings:   actions.setTypeFilter(.meeting)
        case .filterDecisions:  actions.setTypeFilter(.decision)
        case .filterQuestions:  actions.setTypeFilter(.question)
        case .filterReferences: actions.setTypeFilter(.reference)
        }
    }
}

#endif
