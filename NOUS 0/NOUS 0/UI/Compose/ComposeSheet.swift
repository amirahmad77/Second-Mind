import SwiftUI

/// Compose-from-atoms — turn the user's notes into a draft.
///
/// Flow:
///   1. Type a writing intent ("a post about distributed consensus")
///   2. Tap "find atoms" → semantic search via backend, results listed
///   3. Drag-reorder + toggle inclusion of each atom
///   4. Tap "draft" → /v1/compose streams paragraphs w/ inline [atom:N] cites
///   5. Copy markdown
struct ComposeSheet: View {
    let store: AtomStore
    let backend: NousBackendClient
    let userID: UUID
    let onDismiss: () -> Void
    let onPickAtom: (AtomSnapshot) -> Void

    @State private var intent: String = ""
    @State private var tone: Tone = .post
    @State private var picks: [AtomSnapshot] = []
    @State private var includeIDs: Set<UUID> = []
    @State private var draftText: String = ""
    @State private var stage: String = ""
    @State private var streaming = false
    @State private var searching = false
    @State private var error: String?

    enum Tone: String, CaseIterable, Identifiable {
        case post, essay, outline
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NSpace.lg) {
            header
            intentField
            toneRow
            actionsRow

            if !picks.isEmpty {
                Text("// atoms · drag to reorder")
                    .font(NFont.mono(10))
                    .tracking(1.4)
                    .textCase(.uppercase)
                    .foregroundStyle(NSColorToken.textGhost)
                atomList
            }

            if !draftText.isEmpty || streaming {
                Divider().background(NSColorToken.textGhost.opacity(0.25))
                draftSection
            }

            if let error {
                Text(error)
                    .font(NFont.mono(11))
                    .foregroundStyle(NSColorToken.Phos.orange)
            }
            Spacer()
        }
        .padding(NSpace.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(NSColorToken.inkPaper.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    // MARK: - Subviews

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("// compose")
                    .font(NFont.mono(10))
                    .tracking(1.6)
                    .textCase(.uppercase)
                    .foregroundStyle(NSColorToken.textGhost)
                Text("write from your notes")
                    .font(NFont.body(17))
                    .foregroundStyle(NSColorToken.textPrimary)
            }
            Spacer()
            Button("close") { onDismiss() }
                .font(NFont.mono(12))
                .foregroundStyle(NSColorToken.textGhost)
        }
    }

    private var intentField: some View {
        TextField("e.g. a post about distributed consensus", text: $intent, axis: .vertical)
            .font(NFont.body(15))
            .foregroundStyle(NSColorToken.textPrimary)
            .lineLimit(1...3)
            .padding(NSpace.md)
            .background(NSColorToken.inkRaised)
            .overlay(Rectangle().stroke(NSColorToken.textGhost.opacity(0.3), lineWidth: 0.5))
    }

    private var toneRow: some View {
        HStack(spacing: NSpace.xs) {
            ForEach(Tone.allCases) { t in
                let active = tone == t
                Button { tone = t } label: {
                    Text(t.rawValue)
                        .font(NFont.mono(11))
                        .tracking(1.2)
                        .textCase(.uppercase)
                        .foregroundStyle(active ? NSColorToken.Phos.cyan : NSColorToken.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 30)
                        .background(active ? NSColorToken.inkRaised : Color.clear)
                        .overlay(Rectangle().stroke(
                            active ? NSColorToken.Phos.cyan.opacity(0.5) : NSColorToken.textGhost.opacity(0.3),
                            lineWidth: 0.5))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var actionsRow: some View {
        HStack(spacing: NSpace.sm) {
            Button {
                Task { await findAtoms() }
            } label: {
                HStack(spacing: 6) {
                    if searching { ProgressView().controlSize(.mini).tint(NSColorToken.Phos.cyan) }
                    Text(picks.isEmpty ? "find atoms" : "refind")
                        .font(NFont.mono(12))
                        .tracking(1.0)
                        .textCase(.uppercase)
                }
                .foregroundStyle(NSColorToken.Phos.cyan)
                .frame(maxWidth: .infinity, minHeight: 38)
                .background(NSColorToken.inkRaised)
                .overlay(Rectangle().stroke(NSColorToken.Phos.cyan.opacity(0.5), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .disabled(intent.trimmingCharacters(in: .whitespaces).count < 2 || searching)

            if !picks.isEmpty {
                Button {
                    Task { await runDraft() }
                } label: {
                    HStack(spacing: 6) {
                        if streaming { ProgressView().controlSize(.mini).tint(NSColorToken.inkVoid) }
                        Text(streaming ? "drafting…" : "draft")
                            .font(NFont.mono(12))
                            .tracking(1.0)
                            .textCase(.uppercase)
                    }
                    .foregroundStyle(NSColorToken.inkVoid)
                    .frame(maxWidth: .infinity, minHeight: 38)
                    .background(NSColorToken.Phos.cyan)
                }
                .buttonStyle(.plain)
                .disabled(streaming || includedAtoms.isEmpty)
            }
        }
    }

    private var atomList: some View {
        ScrollView {
            VStack(spacing: 4) {
                ForEach(picks, id: \.id) { a in
                    let on = includeIDs.contains(a.id)
                    HStack(alignment: .top, spacing: NSpace.sm) {
                        Image(systemName: on ? "checkmark.square.fill" : "square")
                            .foregroundStyle(on ? NSColorToken.Phos.cyan : NSColorToken.textGhost)
                            .onTapGesture {
                                if on { includeIDs.remove(a.id) } else { includeIDs.insert(a.id) }
                            }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(a.displayContent.split(whereSeparator: \.isNewline).first.map(String.init) ?? "")
                                .font(NFont.body(13))
                                .foregroundStyle(on ? NSColorToken.textPrimary : NSColorToken.textSecondary)
                                .lineLimit(2)
                            Text(a.createdAt.formatted(.dateTime.month(.abbreviated).day().year()))
                                .font(NFont.mono(9))
                                .foregroundStyle(NSColorToken.textGhost)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, NSpace.sm)
                    .background(NSColorToken.inkRaised.opacity(on ? 0.7 : 0.3))
                    .contentShape(Rectangle())
                    .onTapGesture { onPickAtom(a) }
                }
            }
        }
        .frame(maxHeight: 220)
    }

    private var draftSection: some View {
        VStack(alignment: .leading, spacing: NSpace.xs) {
            HStack {
                Text(stage.isEmpty ? "// draft" : "// \(stage)")
                    .font(NFont.mono(10))
                    .tracking(1.4)
                    .textCase(.uppercase)
                    .foregroundStyle(NSColorToken.textGhost)
                Spacer()
                if !draftText.isEmpty {
                    Button {
                        #if os(iOS) || os(visionOS)
                        UIPasteboard.general.string = renderedDraft
                        Haptics.shared.softTick()
                        #elseif os(macOS)
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(renderedDraft, forType: .string)
                        #endif
                    } label: {
                        Text("copy")
                            .font(NFont.mono(11))
                            .tracking(1.2)
                            .textCase(.uppercase)
                            .foregroundStyle(NSColorToken.Phos.cyan)
                    }
                }
            }
            ScrollView {
                Text(renderedDraft)
                    .font(NFont.body(14))
                    .foregroundStyle(NSColorToken.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 260)
        }
    }

    // MARK: - Helpers

    private var includedAtoms: [AtomSnapshot] {
        picks.filter { includeIDs.contains($0.id) }
    }

    /// Replaces [atom:N] markers w/ a stable preview prefix so the user can
    /// see which atom each cite refers to.
    private var renderedDraft: String {
        var out = draftText
        for (i, a) in includedAtoms.enumerated() {
            let n = i + 1
            let preview = a.displayContent.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            let trimmed = String(preview.prefix(40))
            out = out.replacingOccurrences(of: "[atom:\(n)]", with: "[\(n) · \(trimmed)]")
        }
        return out
    }

    // MARK: - Actions

    private func findAtoms() async {
        searching = true
        error = nil
        defer { searching = false }
        do {
            let resp = try await backend.search(userID: userID, query: intent, limit: 12)
            // Map hits → AtomSnapshot from store. Backend doesn't ship a snapshot,
            // so look up locally by id; fall back to a synthetic snapshot for
            // remote-only atoms.
            var results: [AtomSnapshot] = []
            for hit in resp.hits {
                if let local = store.atoms[hit.atom_id] {
                    results.append(local)
                }
            }
            picks = results
            includeIDs = Set(results.prefix(8).map(\.id))   // pre-include top 8
            if results.isEmpty { error = "no matching atoms found" }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func runDraft() async {
        streaming = true
        draftText = ""
        stage = "fetching"
        error = nil
        defer { streaming = false }
        do {
            let stream = try await backend.compose(
                userID: userID,
                intent: intent,
                atomIDs: includedAtoms.map(\.id),
                tone: tone.rawValue
            )
            for try await ev in stream {
                switch ev {
                case .update(let s, _): stage = s
                case .token(let t):     draftText += t
                case .done:             return
                case .citation:         continue
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
