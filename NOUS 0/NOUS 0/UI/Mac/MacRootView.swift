#if os(macOS)
import SwiftUI
import SwiftData
import Accelerate

// ─── MacRootView ─────────────────────────────────────────────────────────────
//
// Three-column NavigationSplitView: sidebar → list → detail.
// Owns all shared state: store, clients, selection, active panel.
//
// Column widths:
//   Sidebar  : 200 pt (fixed)
//   List     : 280 pt min, 380 max
//   Detail   : flexible remainder
//
// Keyboard contract:
//   ⌘N          → open capture panel
//   ⌘F          → focus search
//   ⌘K          → command palette (future)
//   ⌘⌫          → delete selected atom
//   ↑ / ↓       → navigate list (handled by List natively)
//   Esc         → deselect / close detail

@MainActor
struct MacRootView: View {

    @Environment(\.modelContext) private var ctx

    // Clients
    @State private var store: AtomStore?
    @State private var gemini    = GeminiClient()
    @State private var supabase  = SupabaseClient()
    @State private var backend   = NousBackendClient()
    @State private var sync: SyncDaemon?

    // Navigation
    @State private var sidebarSelection: MacSidebarItem = .stream
    @State private var selectedAtomID: UUID?

    // Search
    @State private var searchText: String = ""

    // Capture panel
    @State private var showCapture = false

    // Undo
    @State private var undoManager = DeleteUndoManager()

    var body: some View {
        Group {
            if let store {
                NavigationSplitView(columnVisibility: .constant(.all)) {
                    MacSidebar(
                        selection: $sidebarSelection,
                        store: store
                    )
                    .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
                } content: {
                    contentColumn(store: store)
                        .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 420)
                } detail: {
                    detailColumn(store: store)
                }
                .navigationTitle("")
                // Toolbar lives at the NavigationSplitView level
                .toolbar { macToolbar(store: store) }
                // Capture panel sheet
                .sheet(isPresented: $showCapture) {
                    MacCapturePanel(store: store) {
                        showCapture = false
                    }
                }
                // Undo toast
                .overlay(alignment: .bottom) {
                    if undoManager.pendingAtom != nil {
                        DeleteUndoToast(manager: undoManager, store: store)
                            .padding(.bottom, NSpace.xl)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                // Delete shortcut
                .onDeleteCommand {
                    guard let id = selectedAtomID,
                          let atom = store.atoms[id] else { return }
                    undoManager.scheduleDelete(atom: atom, store: store)
                    selectedAtomID = nil
                }
            } else {
                // Bootstrap in progress
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(NSColorToken.inkVoid)
            }
        }
        .animation(.nDrawer, value: undoManager.pendingAtom?.id)
        .preferredColorScheme(.dark)
        .task { bootstrap() }
        // Global ⌘N capture
        .keyboardShortcut("n", modifiers: .command)
        .onReceive(NotificationCenter.default.publisher(for: .nousOpenCapture)) { _ in
            showCapture = true
        }
    }

    // MARK: – Content column

    @ViewBuilder
    private func contentColumn(store: AtomStore) -> some View {
        switch sidebarSelection {
        case .stream, .type:
            MacAtomList(
                store: store,
                filter: sidebarFilter,
                searchText: $searchText,
                selectedAtomID: $selectedAtomID,
                onDelete: { atom in undoManager.scheduleDelete(atom: atom, store: store) }
            )
        case .search:
            MacSearchView(store: store, backend: backend, gemini: gemini, supabase: supabase) { atom in
                sidebarSelection = .stream
                selectedAtomID = atom.id
            }
        case .tasks:
            MacAtomList(
                store: store,
                filter: .taskOnly,
                searchText: $searchText,
                selectedAtomID: $selectedAtomID,
                onDelete: { atom in undoManager.scheduleDelete(atom: atom, store: store) }
            )
        case .synthesis:
            // Synthesis lives in detail — show placeholder here
            ContentUnavailableView(
                "// synthesize",
                systemImage: "sparkles",
                description: Text("Ask a question in the detail panel →")
            )
            .foregroundStyle(NSColorToken.textGhost)
        }
    }

    // MARK: – Detail column

    @ViewBuilder
    private func detailColumn(store: AtomStore) -> some View {
        if sidebarSelection == .synthesis {
            MacSynthesisView(store: store, backend: backend)
        } else if let id = selectedAtomID, let atom = store.atoms[id] {
            MacAtomDetail(
                atom: atom,
                related: related(for: id, store: store),
                store: store,
                onClose: { withAnimation(.nDrawer) { selectedAtomID = nil } },
                onDelete: { a in
                    undoManager.scheduleDelete(atom: a, store: store)
                    selectedAtomID = nil
                },
                onPickRelated: { a in selectedAtomID = a.id }
            )
        } else {
            MacEmptyDetail()
        }
    }

    // MARK: – Toolbar

    @ToolbarContentBuilder
    private func macToolbar(store: AtomStore) -> some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                showCapture = true
            } label: {
                Label("New capture", systemImage: "plus")
            }
            .keyboardShortcut("n", modifiers: .command)
            .help("New capture (⌘N)")
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                sidebarSelection = .synthesis
            } label: {
                Label("Synthesize", systemImage: "sparkles")
            }
            .help("Open synthesis (⌘⌥S)")
            .keyboardShortcut("s", modifiers: [.command, .option])
        }
    }

    // MARK: – Sidebar filter

    private var sidebarFilter: MacAtomListFilter {
        switch sidebarSelection {
        case .stream:         return .all
        case .tasks:          return .taskOnly
        case .type(let t):    return .type(t)
        default:              return .all
        }
    }

    // MARK: – Bootstrap

    private func bootstrap() {
        guard store == nil else { return }
        let sync = SyncDaemon(context: ctx, supabase: supabase, gemini: gemini)
        let store = AtomStore(context: ctx, sync: sync, gemini: gemini)
        store.bootstrap()
        sync.onRemoteEvent = { [weak store] e in store?.applyRemoteEvent(e) }
        sync.bootstrap()
        self.store = store
        self.sync  = sync
        NousLogger.info("mac", "bootstrap complete")
    }

    // MARK: – Related atoms (semantic + lexical fallback)

    private func related(for id: UUID, store: AtomStore) -> [AtomSnapshot] {
        let desc = FetchDescriptor<EmbeddingRecord>()
        let all = (try? ctx.fetch(desc)) ?? []
        guard let src = all.first(where: { $0.atomID == id }) else {
            return lexicalRelated(for: id, store: store)
        }
        let sv = src.toFloatArray()
        guard !sv.isEmpty else { return lexicalRelated(for: id, store: store) }
        let hits = all.compactMap { rec -> (AtomSnapshot, Float)? in
            guard rec.atomID != id,
                  let atom = store.atoms[rec.atomID], !atom.isDeleted else { return nil }
            let v = rec.toFloatArray()
            guard v.count == sv.count else { return nil }
            var dot: Float = 0; vDSP_dotpr(sv, 1, v, 1, &dot, vDSP_Length(sv.count))
            var na: Float = 0; vDSP_svesq(sv, 1, &na, vDSP_Length(sv.count))
            var nb: Float = 0; vDSP_svesq(v, 1, &nb, vDSP_Length(v.count))
            let d = sqrtf(na) * sqrtf(nb)
            let sim = d == 0 ? 0 : dot / d
            return sim >= 0.55 ? (atom, sim) : nil
        }
        .sorted { $0.1 > $1.1 }.prefix(4).map(\.0)
        return hits.isEmpty ? lexicalRelated(for: id, store: store) : Array(hits)
    }

    private func lexicalRelated(for id: UUID, store: AtomStore) -> [AtomSnapshot] {
        guard let a = store.atoms[id] else { return [] }
        let wA = Set(a.displayContent.lowercased().split(separator: " ").map(String.init))
        let tA = Set(a.tags.map(\.value))
        return store.ordered
            .filter { $0.id != id && !$0.isDeleted }
            .map { c -> (AtomSnapshot, Double) in
                var s = 0.0
                if c.type == a.type { s += 0.3 }
                s += Double(tA.intersection(Set(c.tags.map(\.value))).count) * 0.4
                let wB = Set(c.displayContent.lowercased().split(separator: " ").map(String.init))
                s += Double(wA.intersection(wB).count) * 0.05
                return (c, s)
            }
            .filter { $0.1 >= 0.5 }
            .sorted { $0.1 > $1.1 }
            .prefix(4).map(\.0)
    }
}

// MARK: – Empty detail placeholder

private struct MacEmptyDetail: View {
    var body: some View {
        VStack(spacing: NSpace.md) {
            Text("// select an atom")
                .font(NFont.mono(13))
                .foregroundStyle(NSColorToken.textGhost)
            Text("or press ⌘N to capture a new thought")
                .font(NFont.mono(11))
                .foregroundStyle(NSColorToken.textGhost.opacity(0.55))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NSColorToken.inkVoid)
    }
}

// MARK: – Notification name

extension Notification.Name {
    static let nousOpenCapture = Notification.Name("nous.openCapture")
}

#endif
