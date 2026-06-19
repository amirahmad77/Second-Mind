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
    @State private var showAccount = false
    /// Local presentation of the daily briefing — kept self-contained inside the
    /// sidebar so we don't thread state through MacRootView.
    @State private var showBriefing = false
    /// Local presentation of the constellation graph — same self-contained pattern
    /// as the briefing; never routed through MacRootView.
    @State private var showGraph = false
    /// Local presentation of the entities / people surface — same self-contained
    /// pattern as the briefing and graph; never routed through MacRootView.
    @State private var showEntities = false

    var body: some View {
        List(selection: $selection) {
            // ── Today / briefing ──────────────────────────────────────────────
            // Stand-alone button (not a List selection tag): tapping presents the
            // briefing sheet rather than swapping the detail pane.
            Section {
                briefingRow
                constellationRow
                entitiesRow
            }

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
        .safeAreaInset(edge: .top, spacing: 0) {
            wordmarkHeader
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            profileFooter
        }
        .frame(minWidth: 180)
        .toolbar(removing: .sidebarToggle)
        .sheet(isPresented: $showBriefing) {
            DailyBriefingView(
                vm: DailyBriefingVM(store: store),
                onPickAtom: { atom in
                    // Dismiss the briefing, surface the stream pane, and broadcast
                    // the atom id. MacRootView owns the actual selection state
                    // (its private `selectedAtomID`); posting the notification lets
                    // it (or any future observer) open the atom without coupling
                    // this sheet to MacRootView internals.
                    showBriefing = false
                    selection = .stream
                    NotificationCenter.default.post(
                        name: .nousSelectAtom,
                        object: nil,
                        userInfo: ["atomID": atom.id.uuidString]
                    )
                    NousLogger.info("store", "briefing pick → select atom",
                                    ["id": atom.id.uuidString])
                },
                onClose: { showBriefing = false }
            )
        }
        .sheet(isPresented: $showGraph) {
            GraphView(
                store: store,
                onPickAtom: { atom in
                    // Same decoupled path as the briefing: dismiss the sheet,
                    // surface the stream pane, and broadcast the atom id for
                    // MacRootView (its private selection state) to open.
                    showGraph = false
                    selection = .stream
                    NotificationCenter.default.post(
                        name: .nousSelectAtom,
                        object: nil,
                        userInfo: ["atomID": atom.id.uuidString]
                    )
                    NousLogger.info("store", "graph pick → select atom",
                                    ["id": atom.id.uuidString])
                },
                onClose: { showGraph = false }
            )
        }
        .sheet(isPresented: $showEntities) {
            EntitiesView(
                store: store,
                onPickAtom: { atom in
                    // Same decoupled path as the briefing/graph: dismiss the
                    // sheet, surface the stream pane, and broadcast the atom id
                    // for MacRootView (its private selection state) to open.
                    showEntities = false
                    selection = .stream
                    NotificationCenter.default.post(
                        name: .nousSelectAtom,
                        object: nil,
                        userInfo: ["atomID": atom.id.uuidString]
                    )
                    NousLogger.info("store", "entities pick → select atom",
                                    ["id": atom.id.uuidString])
                },
                onClose: { showEntities = false }
            )
        }
    }

    // MARK: – Wordmark header

    /// Serif brand wordmark pinned at the top of the sidebar, with the mono
    /// kicker that runs through the rest of the chrome. Restrained — it anchors
    /// the column without competing with the nav.
    private var wordmarkHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("nous")
                .font(NFont.wordmark(22))
                .foregroundStyle(NSColorToken.textPrimary)
            Text("// thinking environment")
                .font(NFont.mono(9))
                .foregroundStyle(NSColorToken.textGhost)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, NSpace.md)
        .padding(.top, NSpace.md)
        .padding(.bottom, NSpace.sm)
        .background(NSColorToken.inkPaper)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Nous, thinking environment")
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: – Briefing row

    private var briefingRow: some View {
        Button {
            showBriefing = true
        } label: {
            Label {
                Text("// today")
                    .font(NFont.mono(12))
                    .foregroundStyle(NSColorToken.textSecondary)
            } icon: {
                Image(systemName: "sun.max")
                    .foregroundStyle(NSColorToken.Phos.amber)
                    .imageScale(.small)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
    }

    // MARK: – Constellation row

    private var constellationRow: some View {
        Button {
            showGraph = true
        } label: {
            Label {
                Text("// constellation")
                    .font(NFont.mono(12))
                    .foregroundStyle(NSColorToken.textSecondary)
            } icon: {
                Image(systemName: "circle.hexagongrid")
                    .foregroundStyle(NSColorToken.Phos.violet)
                    .imageScale(.small)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
    }

    // MARK: – Entities row

    private var entitiesRow: some View {
        Button {
            showEntities = true
        } label: {
            Label {
                Text("// entities")
                    .font(NFont.mono(12))
                    .foregroundStyle(NSColorToken.textSecondary)
            } icon: {
                Image(systemName: "person.2")
                    .foregroundStyle(NSColorToken.Phos.cyan)
                    .imageScale(.small)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
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
        Button {
            showAccount = true
        } label: {
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
                Image(systemName: "ellipsis")
                    .font(.system(size: 9))
                    .foregroundStyle(NSColorToken.textGhost.opacity(0.5))
            }
            .padding(.horizontal, NSpace.md)
            .padding(.vertical, NSpace.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(NSColorToken.inkPaper)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(NSColorToken.textGhost.opacity(0.12))
                .frame(height: 0.5)
        }
        .popover(isPresented: $showAccount, arrowEdge: .top) {
            MacAccountPopover()
        }
    }
}

// MARK: – Account popover

private struct MacAccountPopover: View {
    @State private var confirmSignOut = false
    @State private var confirmDelete  = false
    @State private var isBusy = false
    @State private var errorMsg: String?
    @State private var showPair = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: NSpace.xs) {
                if let name = AuthClient.shared.session?.displayName {
                    Text(name)
                        .font(NFont.body(13))
                        .foregroundStyle(NSColorToken.textPrimary)
                }
                Text(AuthClient.shared.session?.email ?? "")
                    .font(NFont.mono(10))
                    .foregroundStyle(NSColorToken.textGhost)
            }
            .padding(.horizontal, NSpace.lg)
            .padding(.top, NSpace.lg)
            .padding(.bottom, NSpace.md)

            Divider()
                .overlay(NSColorToken.textGhost.opacity(0.12))

            // Sync diagnostic
            SyncDiagnosticPanel()
                .padding(.horizontal, NSpace.lg)
                .padding(.vertical, NSpace.md)

            Divider()
                .overlay(NSColorToken.textGhost.opacity(0.12))

            // Compose
            rowButton("// compose") {
                NotificationCenter.default.post(name: .nousOpenCompose, object: nil)
            }

            rowButton("// pair browser") { showPair = true }

            Divider()
                .overlay(NSColorToken.textGhost.opacity(0.12))

            // Sign out
            if confirmSignOut {
                HStack(spacing: NSpace.md) {
                    Text("// sign out?")
                        .font(NFont.mono(11))
                        .foregroundStyle(NSColorToken.Phos.orange)
                    Spacer()
                    Button("cancel") { confirmSignOut = false }
                        .font(NFont.mono(11))
                        .foregroundStyle(NSColorToken.textGhost)
                        .buttonStyle(.plain)
                    Button("confirm") {
                        isBusy = true
                        Task {
                            await AuthClient.shared.signOut()
                            isBusy = false
                        }
                    }
                    .font(NFont.mono(11))
                    .foregroundStyle(NSColorToken.Phos.orange)
                    .buttonStyle(.plain)
                    .disabled(isBusy)
                }
                .padding(.horizontal, NSpace.lg)
                .padding(.vertical, NSpace.sm)
            } else {
                rowButton("// sign out") { confirmSignOut = true }
            }

            // Delete account
            if confirmDelete {
                HStack(spacing: NSpace.md) {
                    Text("// delete account — irreversible")
                        .font(NFont.mono(10))
                        .foregroundStyle(NSColorToken.Phos.orange.opacity(0.8))
                    Spacer()
                    Button("cancel") { confirmDelete = false }
                        .font(NFont.mono(10))
                        .foregroundStyle(NSColorToken.textGhost)
                        .buttonStyle(.plain)
                    Button("delete") {
                        isBusy = true
                        Task {
                            try? await AuthClient.shared.deleteAccount()
                            isBusy = false
                        }
                    }
                    .font(NFont.mono(10))
                    .foregroundStyle(NSColorToken.Phos.orange)
                    .buttonStyle(.plain)
                    .disabled(isBusy)
                }
                .padding(.horizontal, NSpace.lg)
                .padding(.vertical, NSpace.sm)
            } else {
                rowButton("// delete account", danger: true) { confirmDelete = true }
            }

            if let errorMsg {
                Text(errorMsg)
                    .font(NFont.mono(10))
                    .foregroundStyle(NSColorToken.Phos.orange)
                    .padding(.horizontal, NSpace.lg)
                    .padding(.bottom, NSpace.sm)
            }
        }
        .frame(width: 280)
        .background(NSColorToken.inkPaper)
        .sheet(isPresented: $showPair) {
            PairBrowserSheet(userID: AuthClient.shared.session?.userID ?? AppEnv.localUserID)
                .frame(width: 380, height: 420)
        }
    }

    private func rowButton(_ label: String, danger: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(NFont.mono(11))
                .foregroundStyle(danger
                    ? NSColorToken.Phos.orange.opacity(0.7)
                    : NSColorToken.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, NSpace.lg)
                .padding(.vertical, NSpace.sm)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: – Notification name

extension Notification.Name {
    /// Posted when the briefing picks an atom to open. `userInfo["atomID"]`
    /// carries the UUID string. MacRootView (or any host) can observe this to
    /// drive its own selection state — kept decoupled so the briefing sheet
    /// never reaches into MacRootView internals.
    static let nousSelectAtom = Notification.Name("nous.selectAtom")
}

#endif
