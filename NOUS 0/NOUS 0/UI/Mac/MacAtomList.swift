#if os(macOS)
import SwiftUI

// ─── MacAtomList ─────────────────────────────────────────────────────────────
//
// Center column: filtered, searchable, keyboard-navigable atom list.
// Grouped by day (same structure as iOS StreamView but Mac-density-appropriate).
//
// Keyboard:
//   ↑/↓ — navigate rows (native List selection)
//   ⌘⌫  — delete (via .onDeleteCommand on parent)
//   Type — start filtering (future: inline search focus)

enum MacAtomListFilter: Equatable {
    case all
    case taskOnly
    case type(AtomType)
    case search(String)
}

struct MacAtomList: View {
    let store: AtomStore
    let filter: MacAtomListFilter
    @Binding var searchText: String
    @Binding var selectedAtomID: UUID?
    let onDelete: (AtomSnapshot) -> Void

    // ─── Multi-select / bulk layer (ADDITIVE — local to MacAtomList) ──────────
    // The single-selection detail binding (`selectedAtomID`, owned by MacRootView)
    // is never mutated by this layer. Bulk mode is a separate interaction surface.
    @State private var bulkMode: Bool = false
    @State private var bulkSelection: Set<UUID> = []
    @State private var bulkTagDraft: String = ""
    @FocusState private var bulkTagFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Search bar — always visible, filters inline
            searchBar
                .padding(.horizontal, NSpace.md)
                .padding(.vertical, NSpace.sm)
                .background(NSColorToken.inkPaper)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(NSColorToken.textGhost.opacity(0.12))
                        .frame(height: 0.5)
                }

            if filtered.isEmpty {
                emptyState
            } else {
                listBody
            }

            // Bulk action bar — slides up when a selection exists
            if bulkMode && !bulkSelection.isEmpty {
                bulkActionBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(NSColorToken.inkPaper)
        .animation(.nEaseOutQuint, value: bulkMode)
        .animation(.nEaseOutQuint, value: bulkSelection.isEmpty)
        // ⌘A — select all visible/filtered atoms (also enters bulk mode).
        .onExitCommand { exitBulkMode() }   // Esc
        .background(selectAllShortcut)
    }

    // MARK: – Search bar

    private var searchBar: some View {
        HStack(spacing: NSpace.sm) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(NSColorToken.textGhost)
                .imageScale(.small)
                .accessibilityHidden(true)
            TextField("", text: $searchText, prompt: Text("// filter")
                .font(NFont.mono(12))
                .foregroundStyle(NSColorToken.textGhostDim)
            )
            .font(NFont.mono(12))
            .foregroundStyle(NSColorToken.textPrimary)
            .textFieldStyle(.plain)
            .accessibilityLabel("Filter atoms")

            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(NSColorToken.textGhost)
                }
                .buttonStyle(.plain)
                .help("Clear filter")
                .accessibilityLabel("Clear filter")
            }

            // Bulk-mode toggle — small mono affordance matching list chrome.
            Button { toggleBulkMode() } label: {
                Image(systemName: bulkMode ? "checklist.checked" : "checklist")
                    .foregroundStyle(bulkMode ? NSColorToken.Phos.cyan : NSColorToken.textGhost)
                    .imageScale(.small)
            }
            .buttonStyle(.plain)
            .help(bulkMode ? "Exit select mode (Esc)" : "Select multiple")
            .accessibilityLabel(bulkMode ? "Exit select mode" : "Select multiple atoms")
        }
    }

    // MARK: – List

    private var listBody: some View {
        List(selection: $selectedAtomID) {
            ForEach(groups, id: \.date) { group in
                Section {
                    ForEach(group.atoms) { atom in
                        MacAtomRow(
                            atom: atom,
                            isSelected: selectedAtomID == atom.id,
                            inboundCount: store.inboundCount(of: atom.id),
                            bulkMode: bulkMode,
                            isBulkSelected: bulkSelection.contains(atom.id)
                        )
                        .tag(atom.id)
                        .listRowBackground(rowBackground(for: atom))
                        .listRowInsets(EdgeInsets(
                            top: 0,
                            leading: 0,
                            bottom: 0,
                            trailing: NSpace.md
                        ))
                        // In bulk mode, a tap toggles membership instead of opening
                        // detail. Single-click → detail is preserved when not in bulk.
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if bulkMode { toggleMembership(atom.id) }
                            else        { selectedAtomID = atom.id }
                        }
                        .contextMenu {
                            if bulkMode {
                                Button { toggleMembership(atom.id) } label: {
                                    Label(bulkSelection.contains(atom.id) ? "Deselect" : "Select",
                                          systemImage: bulkSelection.contains(atom.id) ? "circle" : "checkmark.circle")
                                }
                            } else {
                                Button {
                                    enterBulkMode(selecting: atom.id)
                                } label: {
                                    Label("Select", systemImage: "checkmark.circle")
                                }
                            }
                            Button(role: .destructive) {
                                onDelete(atom)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            Button {
                                selectedAtomID = atom.id
                            } label: {
                                Label("Open", systemImage: "arrow.right.circle")
                            }
                        }
                    }
                } header: {
                    Text(group.label)
                        .font(NFont.mono(10))
                        .foregroundStyle(NSColorToken.textGhost)
                        .textCase(nil)
                        .accessibilityAddTraits(.isHeader)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(NSColorToken.inkPaper)
        .animation(.nEaseOutQuint, value: filtered.map(\.id))
    }

    /// Row wash: a phosphor-tinted wash for both bulk selection (in bulk mode) and
    /// single selection — the unified selection language shared with iOS AtomRow.
    /// Bulk wash sits slightly stronger so it reads in a multi-row context.
    private func rowBackground(for atom: AtomSnapshot) -> Color {
        if bulkMode && bulkSelection.contains(atom.id) {
            return atom.type.phosphor.opacity(0.14)
        }
        return selectedAtomID == atom.id
            ? atom.type.phosphor.opacity(0.12)
            : Color.clear
    }

    // MARK: – Bulk action bar

    private var bulkActionBar: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(NSColorToken.textGhost.opacity(0.12))
                .frame(height: 0.5)

            HStack(spacing: NSpace.sm) {
                Text("\(bulkSelection.count) selected")
                    .font(NFont.monoSmall(11))
                    .foregroundStyle(NSColorToken.textSecondary)
                    .monospacedDigit()

                Spacer(minLength: NSpace.sm)

                // Add tag — inline field, commits on Return.
                HStack(spacing: NSpace.xs) {
                    Image(systemName: "number")
                        .imageScale(.small)
                        .foregroundStyle(NSColorToken.textGhost)
                    TextField("tag", text: $bulkTagDraft)
                        .font(NFont.mono(11))
                        .foregroundStyle(NSColorToken.textPrimary)
                        .textFieldStyle(.plain)
                        .frame(width: 70)
                        .focused($bulkTagFocused)
                        .onSubmit(commitBulkTag)
                        .accessibilityLabel("Add tag to selected atoms")
                }

                // Set type
                Menu {
                    ForEach(AtomType.allCases, id: \.self) { type in
                        Button(type.label.capitalized) {
                            store.bulkSetType(Array(bulkSelection), to: type)
                        }
                    }
                } label: {
                    Image(systemName: "circle.grid.2x2")
                        .imageScale(.small)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Set type")

                // Set due
                Menu {
                    Button("Today")    { store.bulkSetDue(Array(bulkSelection), to: startOfToday()) }
                    Button("Tomorrow") { store.bulkSetDue(Array(bulkSelection), to: startOfTomorrow()) }
                    Divider()
                    Button("Clear due") { store.bulkSetDue(Array(bulkSelection), to: nil) }
                } label: {
                    Image(systemName: "calendar")
                        .imageScale(.small)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Set due date")

                // Delete
                Button(role: .destructive) {
                    let ids = Array(bulkSelection)
                    store.bulkDelete(ids)
                    bulkSelection.removeAll()
                } label: {
                    Image(systemName: "trash")
                        .imageScale(.small)
                        .foregroundStyle(NSColorToken.Phos.orange)
                }
                .buttonStyle(.plain)
                .help("Delete selected")
                .accessibilityLabel("Delete selected atoms")

                // Clear selection
                Button { bulkSelection.removeAll() } label: {
                    Image(systemName: "xmark")
                        .imageScale(.small)
                        .foregroundStyle(NSColorToken.textGhost)
                }
                .buttonStyle(.plain)
                .help("Clear selection")
                .accessibilityLabel("Clear selection")
            }
            .padding(.horizontal, NSpace.md)
            .padding(.vertical, NSpace.sm)
            .background(NSColorToken.inkRaised)
        }
    }

    /// Invisible button hosting the ⌘A shortcut so it works regardless of focus.
    private var selectAllShortcut: some View {
        Button(action: selectAllVisible) { EmptyView() }
            .buttonStyle(.plain)
            .keyboardShortcut("a", modifiers: .command)
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    // MARK: – Bulk helpers

    private func toggleBulkMode() {
        if bulkMode { exitBulkMode() } else { bulkMode = true }
    }

    private func enterBulkMode(selecting id: UUID) {
        bulkMode = true
        bulkSelection.insert(id)
    }

    private func exitBulkMode() {
        bulkMode = false
        bulkSelection.removeAll()
        bulkTagDraft = ""
        bulkTagFocused = false
    }

    private func toggleMembership(_ id: UUID) {
        if bulkSelection.contains(id) { bulkSelection.remove(id) }
        else                          { bulkSelection.insert(id) }
    }

    private func selectAllVisible() {
        bulkMode = true
        bulkSelection = Set(filtered.map(\.id))
    }

    private func commitBulkTag() {
        let tag = bulkTagDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty, !bulkSelection.isEmpty else { return }
        store.bulkAddTag(Array(bulkSelection), tag: tag)
        bulkTagDraft = ""
    }

    private func startOfToday() -> Date {
        Calendar.current.startOfDay(for: Date())
    }

    private func startOfTomorrow() -> Date {
        let cal = Calendar.current
        return cal.startOfDay(for: cal.date(byAdding: .day, value: 1, to: Date()) ?? Date())
    }

    // MARK: – Empty state

    private var emptyState: some View {
        VStack(spacing: NSpace.sm) {
            Text(searchText.isEmpty ? "// nothing here yet" : "// no results")
                .font(NFont.mono(12))
                .foregroundStyle(NSColorToken.textGhost)
            if searchText.isEmpty {
                Text("⌘N to capture your first thought")
                    .font(NFont.mono(10))
                    .foregroundStyle(NSColorToken.textGhostDim)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: – Filtering

    private var filtered: [AtomSnapshot] {
        let base = store.ordered.filter { !$0.isDeleted }
        let byFilter: [AtomSnapshot]
        switch filter {
        case .all:          byFilter = base
        case .taskOnly:     byFilter = base.filter { $0.type == .task }
        case .type(let t):  byFilter = base.filter { $0.type == t }
        case .search:       byFilter = base
        }
        guard !searchText.isEmpty else { return byFilter }
        let q = searchText.lowercased()
        return byFilter.filter {
            $0.displayContent.lowercased().contains(q) ||
            $0.tags.contains { $0.value.lowercased().contains(q) }
        }
    }

    private var groups: [MacDayGroup] {
        let cal = Calendar.current
        var result: [MacDayGroup] = []
        for atom in filtered {
            let day = cal.startOfDay(for: atom.createdAt)
            if let idx = result.firstIndex(where: { $0.date == day }) {
                result[idx].atoms.append(atom)
            } else {
                let label = dayLabel(for: atom.createdAt)
                result.append(MacDayGroup(date: day, label: label, atoms: [atom]))
            }
        }
        return result
    }

    private func dayLabel(for date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date)     { return "// today" }
        if cal.isDateInYesterday(date) { return "// yesterday" }
        return "// " + date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }
}

// MARK: – Day group

private struct MacDayGroup {
    let date: Date
    let label: String
    var atoms: [AtomSnapshot]
}

// MARK: – Atom row (Mac density)

private struct MacAtomRow: View {
    let atom: AtomSnapshot
    let isSelected: Bool
    var inboundCount: Int = 0
    var bulkMode: Bool = false
    var isBulkSelected: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // 2px phosphor left-edge bar on selection (single OR bulk) — shared
            // selection language with iOS AtomRow.
            Rectangle()
                .fill((isSelected || (bulkMode && isBulkSelected))
                      ? atom.type.phosphor.opacity(0.85) : Color.clear)
                .frame(width: 2)
                .animation(.nEaseOutQuint, value: isSelected)
                .animation(.nEaseOutQuint, value: isBulkSelected)

            HStack(alignment: .top, spacing: NSpace.sm) {
                // Bulk-mode checkbox — replaces nothing; sits before the type dot.
                if bulkMode {
                    Image(systemName: isBulkSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 13))
                        .foregroundStyle(isBulkSelected
                                         ? atom.type.phosphor
                                         : NSColorToken.textGhost)
                        .padding(.top, 1)
                        .accessibilityHidden(true)
                        .animation(.nPress, value: isBulkSelected)
                }

                // Type dot — on/off chroma shared with iOS: full color when the
                // row is the active selection, dimmed otherwise. Bulk membership
                // also counts as "on" so selected rows read at full chroma.
                let dotActive = isSelected || (bulkMode && isBulkSelected)
                Circle()
                    .fill(atom.type.phosphor)
                    .frame(width: 6, height: 6)
                    .opacity(dotActive ? 1.0 : NSColorToken.Phos.dimOpacity)
                    .shadow(color: atom.type.phosphor.opacity(dotActive ? 0.55 : 0.20),
                            radius: dotActive ? NSColorToken.Phos.activeGlow : 4)
                    .padding(.top, 5)
                    .animation(.nEaseOutQuint, value: dotActive)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: NSpace.xs) {
                    // One-liner — full weight always; scales with Dynamic Type
                    // to match the iOS stream row (mono chrome below stays fixed).
                    Text(atom.oneLiner)
                        .nDynamicBody(13)
                        .foregroundStyle(NSColorToken.textPrimary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .contentTransition(.opacity)

                    // P1: Meta line — ghost, clearly subordinate
                    HStack(spacing: NSpace.xs) {
                        Text(atom.createdAt.formatted(date: .omitted, time: .shortened))
                            .font(NFont.mono(10))
                            .foregroundStyle(NSColorToken.textGhostDim)
                            .monospacedDigit()

                        // P4: Inbound count — "← N" not "↩N"
                        if inboundCount > 0 {
                            Text("· ← \(inboundCount)")
                                .font(NFont.mono(10))
                                .foregroundStyle(atom.type.phosphor.opacity(0.65))
                                .monospacedDigit()
                        }

                        if atom.isRefining {
                            Text("· refining")
                                .font(NFont.mono(10))
                                .foregroundStyle(atom.type.phosphor.opacity(0.70))
                        }
                    }

                    // Tags — flat ghost text, minimal footprint
                    if !atom.tags.isEmpty {
                        Text(atom.tags.prefix(3).map(\.value).joined(separator: " · "))
                            .font(NFont.mono(9))
                            .foregroundStyle(NSColorToken.textGhostDim)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }

                Spacer(minLength: 0)
            }
            // P2: More breathing room
            .padding(.vertical, NSpace.sm)
            .padding(.leading, NSpace.sm)
        }
    }
}

#endif
