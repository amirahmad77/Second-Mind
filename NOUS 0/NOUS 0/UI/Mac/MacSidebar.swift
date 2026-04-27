#if os(macOS)
import SwiftUI

// ─── MacSidebar ───────────────────────────────────────────────────────────────
//
// Left navigation column. Speaks the // mono label language.
//
// Sections:
//   Primary nav   — stream, tasks, search, synthesize
//   By type       — collapsible, shows dot + label per AtomType
//
// Profile chip sits at the bottom (fixed, non-scrolling).

enum MacSidebarItem: Hashable {
    case stream
    case tasks
    case search
    case synthesis
    case type(AtomType)
}

struct MacSidebar: View {
    @Binding var selection: MacSidebarItem
    let store: AtomStore

    @State private var typeFilterExpanded = true

    var body: some View {
        List(selection: $selection) {
            // ── Primary navigation ────────────────────────────────────────────
            Section {
                navRow(item: .stream,    label: "// stream",     icon: "waveform")
                navRow(item: .tasks,     label: "// tasks",      icon: "checkmark.circle")
                navRow(item: .search,    label: "// search",     icon: "magnifyingglass")
                navRow(item: .synthesis, label: "// synthesize", icon: "sparkles")
            }

            // ── By type ───────────────────────────────────────────────────────
            Section("by type", isExpanded: $typeFilterExpanded) {
                ForEach(AtomType.allCases, id: \.self) { t in
                    typeRow(t)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(NSColorToken.inkPaper)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            profileFooter
        }
        .frame(minWidth: 180)
        .toolbar(removing: .sidebarToggle)
    }

    // MARK: – Nav row

    private func navRow(item: MacSidebarItem, label: String, icon: String) -> some View {
        Label {
            Text(label)
                .font(NFont.mono(12))
                .foregroundStyle(selection == item
                    ? NSColorToken.textPrimary
                    : NSColorToken.textSecondary)
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(selection == item
                    ? NSColorToken.Phos.cyan
                    : NSColorToken.textGhost)
                .imageScale(.small)
        }
        .tag(item)
        .listRowBackground(
            selection == item
                ? NSColorToken.inkRaised.opacity(0.7)
                : Color.clear
        )
    }

    // MARK: – Type row

    private func typeRow(_ type: AtomType) -> some View {
        let item = MacSidebarItem.type(type)
        let count = store.ordered.filter { $0.type == type && !$0.isDeleted }.count
        return HStack(spacing: NSpace.sm) {
            Circle()
                .fill(type.phosphor)
                .frame(width: 6, height: 6)
            Text("// \(type.rawValue)")
                .font(NFont.mono(11))
                .foregroundStyle(selection == item
                    ? NSColorToken.textPrimary
                    : NSColorToken.textTertiary)
            Spacer(minLength: 0)
            if count > 0 {
                Text("\(count)")
                    .font(NFont.monoSmall(10))
                    .foregroundStyle(NSColorToken.textGhost)
                    .monospacedDigit()
            }
        }
        .tag(item)
        .listRowBackground(
            selection == item
                ? NSColorToken.inkRaised.opacity(0.7)
                : Color.clear
        )
    }

    // MARK: – Profile footer

    private var profileFooter: some View {
        HStack(spacing: NSpace.sm) {
            Circle()
                .fill(NSColorToken.inkRaised)
                .frame(width: 22, height: 22)
                .overlay {
                    Image(systemName: "person.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(NSColorToken.textGhost)
                }
            Text(AuthClient.shared.session?.email ?? "// signed in")
                .font(NFont.mono(10))
                .foregroundStyle(NSColorToken.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, NSpace.md)
        .padding(.vertical, NSpace.sm)
        .background(NSColorToken.inkPaper)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(NSColorToken.textGhost.opacity(0.12))
                .frame(height: 0.5)
        }
    }
}

#endif
