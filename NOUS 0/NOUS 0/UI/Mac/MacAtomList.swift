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
        }
        .background(NSColorToken.inkPaper)
    }

    // MARK: – Search bar

    private var searchBar: some View {
        HStack(spacing: NSpace.sm) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(NSColorToken.textGhost)
                .imageScale(.small)
            TextField("", text: $searchText, prompt: Text("// filter")
                .font(NFont.mono(12))
                .foregroundStyle(NSColorToken.textGhost.opacity(0.5))
            )
            .font(NFont.mono(12))
            .foregroundStyle(NSColorToken.textPrimary)
            .textFieldStyle(.plain)

            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(NSColorToken.textGhost)
                }
                .buttonStyle(.plain)
            }
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
                            isSelected: selectedAtomID == atom.id
                        )
                        .tag(atom.id)
                        .listRowBackground(
                            selectedAtomID == atom.id
                                ? NSColorToken.inkRaised
                                : Color.clear
                        )
                        .listRowInsets(EdgeInsets(
                            top: NSpace.xs,
                            leading: NSpace.md,
                            bottom: NSpace.xs,
                            trailing: NSpace.md
                        ))
                        .contextMenu {
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
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(NSColorToken.inkPaper)
        .animation(.nEaseOutQuint, value: filtered.map(\.id))
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
                    .foregroundStyle(NSColorToken.textGhost.opacity(0.55))
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

    var body: some View {
        HStack(alignment: .top, spacing: NSpace.sm) {
            // Type dot
            Circle()
                .fill(atom.type.phosphor)
                .frame(width: 6, height: 6)
                .shadow(color: atom.type.phosphor.opacity(0.50), radius: 4)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 2) {
                // One-liner
                Text(atom.oneLiner)
                    .font(NFont.body(13))
                    .foregroundStyle(isSelected
                        ? NSColorToken.textPrimary
                        : NSColorToken.textSecondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .contentTransition(.opacity)

                // Meta line
                HStack(spacing: NSpace.xs) {
                    Text(metaLine)
                        .font(NFont.mono(10))
                        .foregroundStyle(NSColorToken.textGhost)
                        .monospacedDigit()

                    if atom.isRefining {
                        Text("// refining")
                            .font(NFont.mono(10))
                            .foregroundStyle(NSColorToken.Phos.amber.opacity(0.65))
                    }
                }

                // Tags (if any)
                if !atom.tags.isEmpty {
                    TagFlow(hSpacing: NSpace.xs, vSpacing: 2) {
                        ForEach(atom.tags, id: \.self) { tag in
                            TagChip(value: tag.value,
                                    phosphor: atom.type.phosphor,
                                    compact: true)
                        }
                    }
                    .frame(height: 12)
                    .clipped()
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private var metaLine: String {
        atom.createdAt.formatted(date: .omitted, time: .shortened)
    }
}

#endif
