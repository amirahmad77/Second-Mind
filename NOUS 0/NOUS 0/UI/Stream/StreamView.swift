import SwiftUI

struct StreamView: View {
    let store: AtomStore
    @Binding var filter: String
    @Binding var tagFilter: String?
    @Binding var selectedAtom: AtomSnapshot?
    var morphNS: Namespace.ID? = nil
    var sync: SyncDaemon? = nil
    var onDelete: ((AtomSnapshot) -> Void)? = nil
    var onScrollOffsetChanged: (CGFloat) -> Void = { _ in }

    var body: some View {
        let groups = store.groupedByDay(filter: filter, tag: tagFilter)
        let textActive = !filter.isEmpty
        let tagActive = !(tagFilter ?? "").isEmpty
        let anyFilter = textActive || tagActive

        List {
            // Brand wordmark — subtle anchor at the very top of the stream. Also
            // provides the clearance the `// daily` label needs from the floating
            // profile chip, so it doubles as the former top spacer.
            wordmarkHeader
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(.init(top: NSpace.xl, leading: NSpace.xl,
                                     bottom: NSpace.xs, trailing: NSpace.xl))

            if anyFilter {
                filterChip(text: textActive ? filter : nil, tag: tagActive ? tagFilter : nil)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(.init(top: 0, leading: NSpace.xl, bottom: 0, trailing: NSpace.xl))
            }

            if !anyFilter && !store.ordered.isEmpty {
                DailyStrip(
                    store: store,
                    onPickAtom: { atom in
                        withAnimation(.nDrawer) { selectedAtom = atom }
                        Haptics.shared.softTick()
                    }
                )
                .padding(.top, NSpace.md)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(.init())
            }

            if groups.isEmpty {
                EmptyStateView(textActive: textActive, tagActive: tagActive, tag: tagFilter)
                    .frame(maxWidth: .infinity, minHeight: 400)
                    .padding(.top, NSpace.x5)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(.init(top: 0, leading: NSpace.xl, bottom: 0, trailing: NSpace.xl))
            } else {
                ForEach(groups) { g in
                    DayHeader(date: g.day, count: g.atoms.count, mtgCount: g.mtgCount)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(.init(top: 0, leading: NSpace.xl, bottom: 0, trailing: NSpace.xl))
                    ForEach(Array(g.atoms.enumerated()), id: \.element.id) { _, a in
                        AtomRow(
                            atom: a,
                            isSelected: selectedAtom?.id == a.id,
                            morphNS: morphNS,
                            inboundCount: store.inboundCount(of: a.id),
                            onTap: {
                                withAnimation(.nDrawer) { selectedAtom = a }
                                Haptics.shared.softTick()
                            }
                        )
                        .padding(.bottom, NSpace.xs)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(.init(top: 0, leading: NSpace.xl, bottom: 0, trailing: NSpace.xl))
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                onDelete?(a)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            .accessibilityLabel("Delete atom")
                            .accessibilityHint("Removes this atom. Can be undone within 4 seconds.")
                        }
                    }
                }
            }

            // Scroll room so last atom clears centered orb.
            Color.clear
                .frame(height: 160)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(.init())
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .onScrollGeometryChange(for: CGFloat.self) { geo in
            geo.contentOffset.y
        } action: { _, y in
            onScrollOffsetChanged(-y)
        }
        .scrollIndicators(.hidden)
        .refreshable {
            Haptics.shared.softTick()
            sync?.resetPullCursor()
            await sync?.pullNowAndWait()
        }
    }
}

private struct EmptyStateView: View {
    let textActive: Bool
    let tagActive: Bool
    let tag: String?
    var body: some View {
        VStack(alignment: .leading, spacing: NSpace.md) {
            // Ghost dot cluster — vocabulary anchor when vault is empty
            if !textActive && !tagActive {
                HStack(spacing: NSpace.sm) {
                    AtomDot(type: .thought, size: 6).opacity(0.12)
                    AtomDot(type: .task, size: 6).opacity(0.12)
                    AtomDot(type: .decision, size: 6).opacity(0.12)
                    AtomDot(type: .reference, size: 6).opacity(0.12)
                }
                .padding(.bottom, NSpace.xs)
            }
            Text(emptyHeadline)
                .font(NFont.mono(14))
                .foregroundStyle(NSColorToken.textSecondary)
            if !textActive && !tagActive {
                // First-run legend — teach all five orb gestures, calm + restrained.
                VStack(alignment: .leading, spacing: NSpace.sm) {
                    ForEach(gestureHints, id: \.self) { hint in
                        Text(hint)
                            .font(NFont.mono(12))
                            .foregroundStyle(NSColorToken.textGhostDim)
                    }
                }
                .padding(.top, NSpace.sm)
            } else if let sub = emptySubline {
                Text(sub)
                    .font(NFont.mono(12))
                    .foregroundStyle(NSColorToken.textGhost)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
    private let gestureHints = [
        "// tap        → write",
        "// hold       → speak",
        "// swipe up    → search",
        "// swipe right → tasks",
        "// swipe left  → synthesis",
    ]
    private var emptyHeadline: String {
        if textActive && tagActive { return "// nothing matches both filters" }
        if tagActive, let t = tag  { return "// nothing tagged \"\(t)\"" }
        if textActive              { return "// nothing close enough." }
        return "// quiet."
    }
    private var emptySubline: String? {
        // Default (no filter) state is handled by the gesture legend, not this subline.
        if textActive && tagActive   { return nil }
        if tagActive, let t = tag    { return "// tap \"\(t)\" above to clear" }
        if textActive                { return "// try fewer words." }
        return nil
    }
}

// MARK: - Filter chip

extension StreamView {
    /// Serif brand wordmark at the head of the stream. Kept small and ghost-toned
    /// so it never competes with capture or the day groups below it.
    fileprivate var wordmarkHeader: some View {
        Text("nous")
            .font(NFont.wordmark(26))
            .foregroundStyle(NSColorToken.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder fileprivate func filterChip(text: String?, tag: String?) -> some View {
        HStack(spacing: NSpace.sm) {
            Text("// filter:")
                .font(NFont.mono(10))
                .foregroundStyle(NSColorToken.textTertiary)
            if let tag {
                Text(tag)
                    .font(NFont.mono(11))
                    .foregroundStyle(NSColorToken.textSecondary)
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(NSColorToken.Phos.cyan.opacity(0.55))
                            .frame(height: 0.75)
                    }
                    .onTapGesture {
                        Haptics.shared.softTick()
                        withAnimation(.nEaseOutQuint) { tagFilter = nil }
                    }
            }
            if let text {
                Text("·")
                    .font(NFont.mono(10))
                    .foregroundStyle(NSColorToken.textGhost)
                Text("\"\(text)\"")
                    .font(NFont.mono(11))
                    .foregroundStyle(NSColorToken.textSecondary)
            }
            Spacer()
            Button(action: clearFilters) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(NSColorToken.textTertiary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Clear filters")
        }
        .padding(.horizontal, NSpace.xs)
        .padding(.vertical, NSpace.xs)
        .padding(.top, NSpace.lg)
        .padding(.bottom, NSpace.sm)
    }

    fileprivate func clearFilters() {
        Haptics.shared.softTick()
        withAnimation(.nEaseOutQuint) {
            filter = ""
            tagFilter = nil
        }
    }
}
