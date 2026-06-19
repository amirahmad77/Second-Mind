#if os(macOS)
import SwiftUI
import SwiftData

// ─── MacSynthesisView ────────────────────────────────────────────────────────
//
// The Synthesis surface — NOUS's "Phosphor Instrument". Many atoms converge
// into a single answer. Reuses SynthesisVM (embed → local cosine search →
// Gemini answer); this view is purely the macOS presentation layer.
//
// Concept:
//   A mono question field at the top focuses the instrument. While thinking,
//   a constellation of phosphor dots converges toward a point (the app's motion
//   vocabulary, not a stock spinner). The streamed answer reads in body type.
//   A "sources" rail shows the source atoms that fed the answer — each carries
//   its phosphor type dot and is tappable to open in the stream detail pane.
//
// Layout:
//   ┌─ header  : // synthesize  ·  source count  ·  cancel
//   ├─ question : mono TextEditor (⌘↩ to ask)
//   ├─ thinking : converging-atoms indicator + stage label (streaming only)
//   ├─ answer   : streamed text → markdown on done  /  inviting empty state
//   └─ sources  : vertical rail of tappable source atoms (when present)

struct MacSynthesisView: View {
    let store: AtomStore
    let backend: NousBackendClient
    let gemini: GeminiClient
    /// Opens a source atom in the stream detail pane. MacRootView routes this
    /// back to its own selection mechanism (switch to .stream + set selectedAtomID).
    let onPickAtom: (UUID) -> Void

    @Environment(\.modelContext) private var ctx
    @State private var vm: SynthesisVM?
    @FocusState private var focus: Bool

    init(store: AtomStore,
         backend: NousBackendClient,
         gemini: GeminiClient,
         onPickAtom: @escaping (UUID) -> Void) {
        self.store      = store
        self.backend    = backend
        self.gemini     = gemini
        self.onPickAtom = onPickAtom
    }

    var body: some View {
        ZStack(alignment: .top) {
            synthesisBackdrop

            if let vm {
                VStack(spacing: 0) {
                    header(vm: vm)
                    Divider()
                        .overlay(NSColorToken.Phos.violet.opacity(0.20))
                    questionArea(vm: vm)
                    Divider()
                        .overlay(NSColorToken.textGhost.opacity(0.08))
                    mainRegion(vm: vm)
                }
            } else {
                ConvergingAtoms(active: true)
                    .frame(width: 120, height: 120)
                    .frame(maxHeight: .infinity)
            }
        }
        .background(NSColorToken.inkVoid)
        .onDisappear { vm?.cancel() }
        .task {
            let embeddings = loadEmbeddings()
            vm = SynthesisVM(gemini: gemini, store: store, fetchEmbeddings: { embeddings })
            focus = true
        }
    }

    // MARK: – Main region (thinking / answer / empty / sources)

    @ViewBuilder
    private func mainRegion(vm: SynthesisVM) -> some View {
        HStack(spacing: 0) {
            // Primary column — thinking state, answer, or empty invitation.
            primaryColumn(vm: vm)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            // Sources rail — appears only once retrieval has populated citations.
            if !vm.citations.isEmpty {
                Divider().overlay(NSColorToken.textGhost.opacity(0.08))
                sourcesRail(vm: vm)
                    .frame(width: 260)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.nDrawer, value: vm.citations.isEmpty)
    }

    @ViewBuilder
    private func primaryColumn(vm: SynthesisVM) -> some View {
        switch vm.stage {
        case .idle where vm.answer.isEmpty:
            emptyState
        case .embedding, .retrieving:
            thinkingState(vm: vm)
        case .failed(let msg) where vm.answer.isEmpty:
            failureState(msg)
        default:
            // .synthesizing (streaming text in) and .done both render the answer.
            answerArea(vm: vm)
        }
    }

    // MARK: – Embeddings

    private func loadEmbeddings() -> [(atomID: UUID, vector: [Float])] {
        let desc = FetchDescriptor<EmbeddingRecord>()
        let records = (try? ctx.fetch(desc)) ?? []
        return records.map { ($0.atomID, $0.toFloatArray()) }
    }

    // MARK: – Backdrop

    private var synthesisBackdrop: some View {
        RadialGradient(
            colors: [NSColorToken.Phos.violet.opacity(0.14), .clear],
            center: UnitPoint(x: 0.5, y: 0.0),
            startRadius: 0,
            endRadius: 460
        )
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    // MARK: – Header

    private func header(vm: SynthesisVM) -> some View {
        HStack(spacing: NSpace.sm) {
            Circle()
                .fill(NSColorToken.Phos.violet.opacity(0.70))
                .frame(width: 5, height: 5)
            Text("// synthesize")
                .font(NFont.mono(12))
                .foregroundStyle(NSColorToken.Phos.violet.opacity(0.80))

            if !vm.citations.isEmpty {
                Text("·  \(vm.citations.count) source\(vm.citations.count == 1 ? "" : "s")")
                    .font(NFont.mono(10))
                    .foregroundStyle(NSColorToken.textGhost)
                    .contentTransition(.numericText())
            }

            Spacer()

            if vm.isStreaming {
                Button("// cancel") { vm.cancel() }
                    .font(NFont.mono(11))
                    .foregroundStyle(NSColorToken.textGhost)
                    .buttonStyle(.plain)
            } else if vm.stage == .done || !vm.answer.isEmpty {
                Button("// new") { vm.reset(); focus = true }
                    .font(NFont.mono(11))
                    .foregroundStyle(NSColorToken.textGhost)
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, NSpace.xl)
        .padding(.vertical, NSpace.md)
        .animation(.nEaseOutQuint, value: vm.citations.count)
        .animation(.nEaseOutQuint, value: vm.isStreaming)
    }

    // MARK: – Question area

    private func questionArea(vm: SynthesisVM) -> some View {
        @Bindable var vm = vm
        return VStack(alignment: .leading, spacing: NSpace.sm) {
            ZStack(alignment: .topLeading) {
                if vm.question.isEmpty {
                    Text("// ask anything across your atoms…")
                        .font(NFont.mono(14))
                        .foregroundStyle(NSColorToken.textGhost.opacity(0.40))
                        .allowsHitTesting(false)
                        .padding(.top, 2)
                        .padding(.leading, 2)
                }
                TextEditor(text: $vm.question)
                    .font(NFont.mono(14))
                    .foregroundStyle(NSColorToken.textPrimary)
                    .scrollContentBackground(.hidden)
                    .focused($focus)
                    .frame(minHeight: 54, maxHeight: 120)
                    .disabled(vm.isStreaming)
                    .opacity(vm.isStreaming ? 0.5 : 1.0)
            }

            HStack(spacing: NSpace.md) {
                Text("⌘↩ to ask")
                    .font(NFont.mono(9))
                    .foregroundStyle(NSColorToken.textGhost.opacity(0.45))
                Spacer()
                Button {
                    vm.submit()
                } label: {
                    HStack(spacing: NSpace.xs) {
                        Image(systemName: "sparkle")
                            .font(.system(size: 9, weight: .semibold))
                        Text("ask")
                            .font(NFont.mono(12))
                    }
                    .foregroundStyle(vm.canSubmit
                        ? NSColorToken.Phos.violet
                        : NSColorToken.textGhost.opacity(0.6))
                    .padding(.horizontal, NSpace.md)
                    .padding(.vertical, NSpace.xs)
                    .background(
                        Capsule().fill(NSColorToken.Phos.violet.opacity(vm.canSubmit ? 0.12 : 0.0))
                    )
                    .overlay(
                        Capsule().strokeBorder(
                            NSColorToken.Phos.violet.opacity(vm.canSubmit ? 0.35 : 0.10),
                            lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
                .disabled(!vm.canSubmit)
                .keyboardShortcut(.return, modifiers: .command)
                .animation(.nPress, value: vm.canSubmit)
            }
        }
        .padding(.horizontal, NSpace.xl)
        .padding(.top, NSpace.md)
        .padding(.bottom, NSpace.md)
    }

    // MARK: – Empty state

    private var emptyState: some View {
        VStack(spacing: NSpace.lg) {
            ConvergingAtoms(active: false)
                .frame(width: 96, height: 96)
            VStack(spacing: NSpace.sm) {
                Text("converge your atoms into an answer")
                    .font(NFont.detailBody(16))
                    .foregroundStyle(NSColorToken.textSecondary)
                Text("// every note you've captured becomes context")
                    .font(NFont.mono(11))
                    .foregroundStyle(NSColorToken.textGhost.opacity(0.55))
            }
            .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: NSpace.xs) {
                suggestion("what did I decide about pricing?")
                suggestion("summarize my open questions this week")
                suggestion("what connects these meetings?")
            }
            .padding(.top, NSpace.sm)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(NSpace.xl)
    }

    private func suggestion(_ text: String) -> some View {
        Button {
            vm?.question = text
            focus = true
        } label: {
            HStack(spacing: NSpace.sm) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 9))
                    .foregroundStyle(NSColorToken.Phos.violet.opacity(0.5))
                Text(text)
                    .font(NFont.mono(11))
                    .foregroundStyle(NSColorToken.textTertiary)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: – Thinking state (converging atoms)

    private func thinkingState(vm: SynthesisVM) -> some View {
        VStack(spacing: NSpace.lg) {
            ConvergingAtoms(active: true)
                .frame(width: 110, height: 110)
            Text(stageLabel(vm: vm))
                .font(NFont.mono(11))
                .foregroundStyle(NSColorToken.Phos.violet.opacity(0.70))
                .contentTransition(.opacity)
                .animation(.nEaseInOutQuint, value: vm.stage)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity)
    }

    private func stageLabel(vm: SynthesisVM) -> String {
        switch vm.stage {
        case .embedding:    return "// embedding query"
        case .retrieving:   return "// searching knowledge graph"
        case .synthesizing: return "// synthesizing answer"
        default:            return ""
        }
    }

    // MARK: – Answer area

    private func answerArea(vm: SynthesisVM) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NSpace.md) {
                // Live synthesizing pulse above the streaming text.
                if case .synthesizing = vm.stage {
                    HStack(spacing: NSpace.sm) {
                        ConvergingAtoms(active: true)
                            .frame(width: 16, height: 16)
                        Text("// synthesizing answer")
                            .font(NFont.mono(10))
                            .foregroundStyle(NSColorToken.Phos.violet.opacity(0.65))
                    }
                    .transition(.opacity)
                }

                Group {
                    if case .done = vm.stage {
                        MarkdownView(
                            raw: vm.answer,
                            store: store,
                            atomID: UUID(),
                            linkColor: NSColorToken.Phos.violet,
                            onPickAtom: { onPickAtom($0.id) }
                        )
                    } else {
                        Text(vm.answer)
                            .font(NFont.detailBody(15))
                    }
                }
                .foregroundStyle(NSColorToken.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, NSpace.xl)
            .padding(.vertical, NSpace.lg)
        }
        .transition(.opacity)
        .animation(.nEaseOutQuint, value: vm.stage)
    }

    // MARK: – Failure state

    private func failureState(_ msg: String) -> some View {
        VStack(spacing: NSpace.sm) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 18))
                .foregroundStyle(NSColorToken.Phos.orange.opacity(0.65))
            Text("// synthesis failed")
                .font(NFont.mono(12))
                .foregroundStyle(NSColorToken.Phos.orange.opacity(0.75))
            Text(msg)
                .font(NFont.mono(10))
                .foregroundStyle(NSColorToken.textGhost)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(NSpace.xl)
    }

    // MARK: – Sources rail

    private func sourcesRail(vm: SynthesisVM) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: NSpace.sm) {
                Text("// sources")
                    .font(NFont.mono(10))
                    .foregroundStyle(NSColorToken.textGhost)
                Spacer()
                Text("converged")
                    .font(NFont.mono(9))
                    .foregroundStyle(NSColorToken.textGhost.opacity(0.45))
            }
            .padding(.horizontal, NSpace.lg)
            .padding(.vertical, NSpace.md)

            Divider().overlay(NSColorToken.textGhost.opacity(0.08))

            ScrollView {
                LazyVStack(alignment: .leading, spacing: NSpace.xs) {
                    ForEach(vm.citations) { citation in
                        SourceRow(
                            atom: store.atoms[citation.id],
                            snippet: citation.snippet,
                            score: citation.score,
                            onTap: { onPickAtom(citation.id) }
                        )
                    }
                }
                .padding(.horizontal, NSpace.sm)
                .padding(.vertical, NSpace.sm)
            }
        }
        .background(NSColorToken.inkPaper.opacity(0.5))
    }
}

// MARK: – SourceRow

/// One source atom in the rail. Shows its phosphor type dot, a one-line snippet,
/// and the cosine relevance as a faint meter. Tapping opens it in the stream.
private struct SourceRow: View {
    let atom: AtomSnapshot?
    let snippet: String
    let score: Double
    let onTap: () -> Void

    @State private var hovering = false

    private var phosphor: Color {
        atom?.type.phosphor ?? NSColorToken.Phos.violet
    }

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: NSpace.sm) {
                Circle()
                    .fill(phosphor.opacity(0.85))
                    .frame(width: 6, height: 6)
                    .padding(.top, 4)
                    .shadow(color: phosphor.opacity(hovering ? 0.6 : 0.0), radius: 4)

                VStack(alignment: .leading, spacing: 3) {
                    Text(snippet)
                        .font(NFont.mono(11))
                        .foregroundStyle(hovering ? NSColorToken.textPrimary : NSColorToken.textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: NSpace.xs) {
                        if let label = atom?.type.label {
                            Text(label)
                                .font(NFont.monoSmall(8))
                                .foregroundStyle(phosphor.opacity(0.65))
                        }
                        relevanceMeter
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, NSpace.sm)
            .padding(.vertical, NSpace.sm)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(NSColorToken.inkRaised.opacity(hovering ? 0.9 : 0.0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(phosphor.opacity(hovering ? 0.22 : 0.0), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.nPress, value: hovering)
    }

    private var relevanceMeter: some View {
        // score is cosine similarity (>0.45 filtered upstream) — map to 5 ticks.
        let ticks = max(1, min(5, Int(((score - 0.45) / 0.55) * 5) + 1))
        return HStack(spacing: 1.5) {
            ForEach(0..<5, id: \.self) { i in
                Capsule()
                    .fill(phosphor.opacity(i < ticks ? 0.55 : 0.12))
                    .frame(width: 4, height: 2)
            }
        }
    }
}

// MARK: – ConvergingAtoms

/// The Synthesis motion signature: a ring of phosphor-tinted atoms that orbit
/// and, when active, breathe inward toward a converging core — many atoms
/// becoming one answer. When inactive it rests as a calm, dim constellation.
/// Built on the app's named curves (.nBreath) rather than a stock spinner.
private struct ConvergingAtoms: View {
    let active: Bool

    @State private var phase: CGFloat = 0
    @State private var pull: CGFloat = 0   // 0 = resting ring, 1 = converged

    private let dotCount = 6
    private let palette: [Color] = [
        NSColorToken.Phos.cyan,
        NSColorToken.Phos.green,
        NSColorToken.Phos.amber,
        NSColorToken.Phos.blue,
        NSColorToken.Phos.orange,
        NSColorToken.Phos.violet
    ]

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let radius = size * 0.42
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)

            ZStack {
                // Converging core — glows when active.
                Circle()
                    .fill(NSColorToken.Phos.violet.opacity(active ? 0.22 : 0.10))
                    .frame(width: size * 0.18, height: size * 0.18)
                    .position(center)
                    .shadow(color: NSColorToken.Phos.violet.opacity(active ? 0.5 : 0.0),
                            radius: active ? 10 : 0)

                ForEach(0..<dotCount, id: \.self) { i in
                    let baseAngle = (CGFloat(i) / CGFloat(dotCount)) * 2 * .pi
                    let angle = baseAngle + phase
                    // Pull each atom inward as `pull` rises (active breathing).
                    let r = radius * (1 - pull * 0.62)
                    let x = center.x + cos(angle) * r
                    let y = center.y + sin(angle) * r
                    Circle()
                        .fill(palette[i % palette.count].opacity(active ? 0.9 : 0.4))
                        .frame(width: 6, height: 6)
                        .shadow(color: palette[i % palette.count].opacity(active ? 0.55 : 0.0),
                                radius: 4)
                        .position(x: x, y: y)
                }
            }
        }
        .onAppear { startMotion() }
        .onChange(of: active) { _, _ in startMotion() }
    }

    private func startMotion() {
        // Slow continuous orbit.
        withAnimation(.linear(duration: active ? 6 : 14).repeatForever(autoreverses: false)) {
            phase = 2 * .pi
        }
        // Breathing convergence only while active.
        if active {
            withAnimation(.nBreath.repeatForever(autoreverses: true)) {
                pull = 1
            }
        } else {
            withAnimation(.nEaseOutQuint) { pull = 0 }
        }
    }
}

#endif
