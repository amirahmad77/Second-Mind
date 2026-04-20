import SwiftUI

struct StreamView: View {
    let store: AtomStore
    @Binding var filter: String
    @Binding var selectedAtom: AtomSnapshot?
    var morphNS: Namespace.ID? = nil

    var body: some View {
        let groups = store.groupedByDay(filter: filter)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if groups.isEmpty {
                    EmptyStateView(filterActive: !filter.isEmpty)
                        .frame(maxWidth: .infinity, minHeight: 400)
                        .padding(.top, NSpace.x5)
                } else {
                    ForEach(groups) { g in
                        DayHeader(date: g.day, count: g.atoms.count, mtgCount: g.mtgCount)
                        ForEach(Array(g.atoms.enumerated()), id: \.element.id) { idx, a in
                            AtomRow(atom: a,
                                    isSelected: selectedAtom?.id == a.id,
                                    morphNS: morphNS) {
                                withAnimation(.nDrawer) { selectedAtom = a }
                                Haptics.shared.softTick()
                            }
                            .padding(.leading, NSpace.xs)
                            .padding(.bottom, NSpace.md)
                        }
                    }
                }
                Color.clear.frame(height: 200) // Orb safe-area breathing
            }
            .padding(.horizontal, NSpace.xl)
        }
        .scrollIndicators(.hidden)
    }
}

private struct EmptyStateView: View {
    let filterActive: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: NSpace.md) {
            Text(filterActive ? "// nothing close enough." : "// no signal yet.")
                .font(NFont.mono(14))
                .foregroundStyle(NSColorToken.textSecondary)
            if !filterActive {
                Text("tap orb to begin.")
                    .font(NFont.mono(12))
                    .foregroundStyle(NSColorToken.textGhost)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
}
