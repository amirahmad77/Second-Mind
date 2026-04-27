#if os(macOS)
import SwiftUI

// ─── MacSearchView ────────────────────────────────────────────────────────────
//
// Search experience for the Mac center column.
// Two modes:
//   • Local: instant keyword filter across all atoms (no network)
//   • Semantic: backend vector search (requires backend configured)
//
// Search triggers local immediately, semantic after 500ms debounce.
// Results show in the list; tapping opens atom in detail.

struct MacSearchView: View {
    let store: AtomStore
    let backend: NousBackendClient
    let gemini: GeminiClient
    let supabase: SupabaseClient
    let onPickAtom: (AtomSnapshot) -> Void

    @State private var query       = ""
    @State private var localHits: [AtomSnapshot] = []
    @State private var semanticHits: [NousBackendClient.SearchHit] = []
    @State private var isSearching = false
    @State private var error: String?
    @FocusState private var focus: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Search field
            HStack(spacing: NSpace.sm) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(isSearching
                        ? NSColorToken.Phos.blue
                        : NSColorToken.textGhost)
                    .imageScale(.small)
                    .animation(.nEaseOutQuint, value: isSearching)

                TextField("", text: $query, prompt:
                    Text("// search your atoms")
                        .font(NFont.mono(12))
                        .foregroundStyle(NSColorToken.textGhost.opacity(0.5))
                )
                .font(NFont.mono(12))
                .foregroundStyle(NSColorToken.textPrimary)
                .textFieldStyle(.plain)
                .focused($focus)
                .onSubmit { runSearch() }

                if isSearching {
                    ProgressView()
                        .scaleEffect(0.6)
                        .tint(NSColorToken.Phos.blue)
                        .transition(.opacity)
                }
                if !query.isEmpty {
                    Button { clearSearch() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(NSColorToken.textGhost)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, NSpace.md)
            .padding(.vertical, NSpace.sm)
            .background(NSColorToken.inkPaper)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(NSColorToken.textGhost.opacity(0.12))
                    .frame(height: 0.5)
            }

            // Results
            if query.isEmpty {
                emptyPrompt
            } else if localHits.isEmpty && semanticHits.isEmpty && !isSearching {
                noResults
            } else {
                resultsList
            }
        }
        .background(NSColorToken.inkPaper)
        .task { focus = true }
        // Debounced search on query change
        .task(id: query) {
            guard !query.isEmpty else {
                localHits = []
                semanticHits = []
                return
            }
            // Local immediately
            localHits = localSearch(query)
            // Semantic after 500ms
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, !query.isEmpty else { return }
            await runSemanticSearch(query)
        }
    }

    // MARK: – Empty / no-results

    private var emptyPrompt: some View {
        VStack(spacing: NSpace.sm) {
            Text("// type to search")
                .font(NFont.mono(12))
                .foregroundStyle(NSColorToken.textGhost)
            Text("keyword · ↩ for semantic search")
                .font(NFont.mono(10))
                .foregroundStyle(NSColorToken.textGhost.opacity(0.55))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noResults: some View {
        VStack(spacing: NSpace.sm) {
            Text("// no results")
                .font(NFont.mono(12))
                .foregroundStyle(NSColorToken.textGhost)
            Text("try a different query")
                .font(NFont.mono(10))
                .foregroundStyle(NSColorToken.textGhost.opacity(0.55))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: – Results list

    private var resultsList: some View {
        List {
            // Semantic section (if available)
            if !semanticHits.isEmpty {
                Section {
                    ForEach(semanticHits) { hit in
                        if let atom = store.atoms[hit.atom_id] {
                            searchRow(atom: atom, score: hit.score)
                                .onTapGesture { onPickAtom(atom) }
                        }
                    }
                } header: {
                    Text("// semantic")
                        .font(NFont.mono(10))
                        .foregroundStyle(NSColorToken.Phos.blue.opacity(0.70))
                        .textCase(nil)
                }
            }

            // Local keyword section
            if !localHits.isEmpty {
                Section {
                    ForEach(localHits) { atom in
                        searchRow(atom: atom, score: nil)
                            .onTapGesture { onPickAtom(atom) }
                    }
                } header: {
                    Text("// keyword")
                        .font(NFont.mono(10))
                        .foregroundStyle(NSColorToken.textGhost)
                        .textCase(nil)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }

    private func searchRow(atom: AtomSnapshot, score: Double?) -> some View {
        HStack(alignment: .top, spacing: NSpace.sm) {
            Circle()
                .fill(atom.type.phosphor)
                .frame(width: 5, height: 5)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 2) {
                Text(atom.oneLiner)
                    .font(NFont.body(13))
                    .foregroundStyle(NSColorToken.textSecondary)
                    .lineLimit(2)

                HStack(spacing: NSpace.xs) {
                    Text(atom.createdAt.formatted(date: .abbreviated, time: .omitted))
                        .font(NFont.mono(10))
                        .foregroundStyle(NSColorToken.textGhost)
                    if let s = score {
                        Text("// \(Int(s * 100))%")
                            .font(NFont.mono(10))
                            .foregroundStyle(NSColorToken.Phos.blue.opacity(0.55))
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: NSpace.xs, leading: NSpace.md,
                                  bottom: NSpace.xs, trailing: NSpace.md))
    }

    // MARK: – Search logic

    private func localSearch(_ q: String) -> [AtomSnapshot] {
        let lq = q.lowercased()
        return store.ordered
            .filter { !$0.isDeleted }
            .filter { $0.displayContent.lowercased().contains(lq)
                   || $0.tags.contains { $0.value.lowercased().contains(lq) } }
            .prefix(20)
            .map { $0 }
    }

    private func runSearch() {
        guard !query.isEmpty else { return }
        localHits = localSearch(query)
        Task { await runSemanticSearch(query) }
    }

    private func runSemanticSearch(_ q: String) async {
        guard backend.isConfigured else { return }
        let userID = await AppEnv.currentUserID()
        isSearching = true
        defer { isSearching = false }
        do {
            let resp = try await backend.search(userID: userID, query: q)
            semanticHits = resp.hits
            NousLogger.info("mac", "search done", ["hits": resp.hits.count, "q": q])
        } catch {
            NousLogger.error("mac", "search failed", ["error": error.localizedDescription])
        }
    }

    private func clearSearch() {
        query = ""
        localHits = []
        semanticHits = []
        isSearching = false
        focus = true
    }
}

#endif
