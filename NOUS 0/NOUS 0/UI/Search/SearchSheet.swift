import SwiftUI

struct SearchSheet: View {
    let store: AtomStore
    let gemini: GeminiClient
    let supabase: SupabaseClient
    let onDismiss: () -> Void
    let onPickAtom: (AtomSnapshot) -> Void

    @State private var query: String = ""
    @State private var hits: [SearchHit] = []
    @State private var mode: ResultMode = .lexical
    @State private var searchToken: UUID = UUID()
    @FocusState private var focus: Bool

    enum ResultMode { case lexical, semantic, offline }

    struct SearchHit: Identifiable, Hashable {
        let id: UUID                  // atomID
        let atom: AtomSnapshot
        let snippet: String
        let matchRange: Range<String.Index>?
    }

    var body: some View {
        ZStack {
            NSColorToken.inkVoid.opacity(0.95).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider().overlay(NSColorToken.textGhost).padding(.horizontal, NSpace.xl)
                results
            }
        }
        .task { focus = true }
        .onChange(of: query) { _, q in
            // Instant lexical (cheap), debounced semantic (network).
            let lex = lexicalSearch(q.trimmingCharacters(in: .whitespacesAndNewlines))
            hits = lex
            mode = .lexical
            let token = UUID(); searchToken = token
            Task {
                try? await Task.sleep(nanoseconds: 220_000_000) // 220ms debounce
                guard token == searchToken else { return }
                await runSemantic(q, baseLocal: lex)
            }
        }
    }

    private var header: some View {
        HStack(spacing: NSpace.md) {
            Text("//")
                .font(NFont.mono(14))
                .foregroundStyle(NSColorToken.textTertiary)
            TextField("", text: $query, prompt: Text("search your mind").foregroundStyle(NSColorToken.textGhost))
                .textFieldStyle(.plain)
                .font(NFont.body(20))
                .foregroundStyle(NSColorToken.textPrimary)
                .focused($focus)
                .submitLabel(.search)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(NSColorToken.textSecondary)
                    .padding(NSpace.sm)
            }
        }
        .padding(.horizontal, NSpace.xl)
        .padding(.top, NSpace.xxl)
        .padding(.bottom, NSpace.lg)
    }

    @ViewBuilder private var results: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: NSpace.lg) {
                if query.isEmpty {
                    Text("// type to search")
                        .font(NFont.mono(12))
                        .foregroundStyle(NSColorToken.textGhost)
                        .padding(.top, NSpace.xxl)
                } else if hits.isEmpty {
                    Text("// nothing close enough.")
                        .font(NFont.mono(12))
                        .foregroundStyle(NSColorToken.textGhost)
                        .padding(.top, NSpace.xxl)
                } else {
                    if mode == .offline {
                        Text("// offline · lexical only")
                            .font(NFont.mono(10))
                            .foregroundStyle(NSColorToken.textGhost)
                    }
                    ForEach(hits) { h in
                        resultRow(h)
                            .contentShape(Rectangle())
                            .onTapGesture { onPickAtom(h.atom) }
                    }
                }
            }
            .padding(.horizontal, NSpace.xl)
            .padding(.vertical, NSpace.lg)
        }
    }

    private func resultRow(_ h: SearchHit) -> some View {
        HStack(alignment: .top, spacing: NSpace.md) {
            AtomDot(type: h.atom.type).padding(.top, 6)
            VStack(alignment: .leading, spacing: 4) {
                attributed(h.snippet, match: query)
                    .font(NFont.body(15))
                    .foregroundStyle(NSColorToken.textPrimary)
                    .lineLimit(3)
                Text(metaLine(h.atom))
                    .font(NFont.mono(10))
                    .foregroundStyle(NSColorToken.textTertiary)
            }
        }
    }

    private func attributed(_ snippet: String, match q: String) -> Text {
        guard !q.isEmpty, let r = snippet.range(of: q, options: .caseInsensitive) else { return Text(snippet) }
        let pre = String(snippet[snippet.startIndex..<r.lowerBound])
        let hit = String(snippet[r])
        let post = String(snippet[r.upperBound..<snippet.endIndex])
        return Text(pre)
            + Text(hit).foregroundColor(NSColorToken.Phos.cyan).underline()
            + Text(post)
    }

    private func metaLine(_ a: AtomSnapshot) -> String {
        a.createdAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()).lowercased()
    }

    // MARK: Search

    private func runSemantic(_ q: String, baseLocal: [SearchHit]) async {
        let trimmed = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            let vec = try await gemini.embed(trimmed)
            let remoteHits = try await supabase.semanticSearch(queryVector: vec, limit: 20)
            // Stale-guard: query may have changed during await.
            guard q == query else { return }
            let merged = mergeHits(local: baseLocal, remote: remoteHits, query: trimmed)
            if !merged.isEmpty { hits = merged; mode = .semantic }
        } catch {
            if q == query { mode = .offline }
        }
    }

    private func lexicalSearch(_ q: String) -> [SearchHit] {
        guard !q.isEmpty else { return [] }
        var out: [SearchHit] = []
        out.reserveCapacity(min(80, store.ordered.count))
        let limit = 80 // cap result fan-out for big stores
        for a in store.ordered {
            if out.count >= limit { break }
            let body = a.displayContent
            guard let range = body.range(of: q, options: .caseInsensitive) else { continue }
            out.append(SearchHit(id: a.id, atom: a,
                                 snippet: extractSnippet(from: body, around: range),
                                 matchRange: nil))
        }
        return out
    }

    private func extractSnippet(from text: String, around range: Range<String.Index>) -> String {
        let lower = text.index(range.lowerBound, offsetBy: -60, limitedBy: text.startIndex) ?? text.startIndex
        let upper = text.index(range.upperBound, offsetBy: 120, limitedBy: text.endIndex) ?? text.endIndex
        var s = String(text[lower..<upper])
        if lower != text.startIndex { s = "… " + s }
        if upper != text.endIndex { s += " …" }
        return s
    }

    private func mergeHits(local: [SearchHit], remote: [SupabaseClient.SemanticHit], query: String) -> [SearchHit] {
        var byID = [UUID: SearchHit]()
        for h in local { byID[h.id] = h }
        for r in remote {
            guard let atom = store.atoms[r.atom_id] else { continue }
            if byID[r.atom_id] == nil {
                let snip = r.snippet ?? String(atom.displayContent.prefix(160))
                byID[r.atom_id] = SearchHit(id: r.atom_id, atom: atom, snippet: snip, matchRange: nil)
            }
        }
        // Order: semantic rank first, then lexical-only remainder.
        var out: [SearchHit] = []
        var used = Set<UUID>()
        for r in remote {
            if let h = byID[r.atom_id] { out.append(h); used.insert(r.atom_id) }
        }
        for h in local where !used.contains(h.id) { out.append(h) }
        return out
    }
}
