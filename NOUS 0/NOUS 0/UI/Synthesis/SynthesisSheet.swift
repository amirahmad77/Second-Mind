import SwiftUI
import SwiftData

/// Synthesis surface — appears on swipe-down from Orb.
/// Uses Gemini directly: embed query → local cosine search → Gemini answer.
struct SynthesisSheet: View {
    let store: AtomStore
    let gemini: GeminiClient
    let onDismiss: () -> Void
    let onPickAtom: (AtomSnapshot) -> Void

    @Environment(\.modelContext) private var ctx
    @State private var vm: SynthesisVM?
    @FocusState private var focus: Bool

    var body: some View {
        ZStack(alignment: .top) {
            backdrop

            VStack(spacing: 0) {
                header
                Divider()
                    .frame(height: 0.5)
                    .overlay(NSColorToken.textGhost.opacity(0.35))

                if let vm {
                    questionArea(vm: vm)
                    thread(vm: vm)
                }
            }
        }
        .background(NSColorToken.inkVoid.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .task {
            let embeddings = loadEmbeddings()
            vm = SynthesisVM(gemini: gemini, store: store, fetchEmbeddings: { embeddings })
            focus = true
        }
        .onDisappear { vm?.cancel() }
    }

    // MARK: Embeddings

    private func loadEmbeddings() -> [(atomID: UUID, vector: [Float])] {
        let desc = FetchDescriptor<EmbeddingRecord>()
        let records = (try? ctx.fetch(desc)) ?? []
        return records.map { ($0.atomID, $0.toFloatArray()) }
    }

    // MARK: Backdrop

    private var backdrop: some View {
        ZStack {
            RadialGradient(
                colors: [NSColorToken.Phos.blue.opacity(0.20), .clear],
                center: UnitPoint(x: 0.5, y: 0.10),
                startRadius: 0,
                endRadius: 480
            )
            RadialGradient(
                colors: [NSColorToken.Phos.violet.opacity(0.06), .clear],
                center: UnitPoint(x: 0.85, y: 1.02),
                startRadius: 0,
                endRadius: 360
            )
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: NSpace.md) {
            Text("// synthesize")
                .font(NFont.mono(11))
                .foregroundStyle(NSColorToken.textTertiary)
                .textCase(.uppercase)
                .tracking(0.10)
            Spacer()
            if let vm, vm.isStreaming {
                Button(action: { vm.cancel() }) {
                    Text("// stop")
                        .font(NFont.mono(11))
                        .foregroundStyle(NSColorToken.Phos.amber)
                        .padding(.horizontal, NSpace.sm)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
            Button(action: close) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(NSColorToken.textSecondary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, NSpace.xl)
        .padding(.top, NSpace.lg)
        .padding(.bottom, NSpace.md)
    }

    // MARK: Question

    private func questionArea(vm: SynthesisVM) -> some View {
        VStack(alignment: .leading, spacing: NSpace.sm) {
            Text(vm.turns.isEmpty ? "// ask your mind" : "// ask a follow-up")
                .font(NFont.mono(10))
                .foregroundStyle(NSColorToken.textGhost)
            HStack(alignment: .top, spacing: NSpace.md) {
                TextField("",
                          text: Binding(get: { vm.question }, set: { vm.question = $0 }),
                          prompt: Text("what was I thinking about…")
                            .foregroundStyle(NSColorToken.textGhost),
                          axis: .vertical)
                    .lineLimit(1...4)
                    .font(NFont.body(18))
                    .foregroundStyle(NSColorToken.textPrimary)
                    .focused($focus)
                    .submitLabel(.go)
                    .onSubmit { vm.submit() }
                if vm.canSubmit && !vm.question.isEmpty {
                    Button(action: { vm.submit() }) {
                        Text("// ask")
                            .font(NFont.mono(11))
                            .foregroundStyle(NSColorToken.Phos.cyan)
                            .padding(.horizontal, NSpace.sm)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, NSpace.xl)
        .padding(.top, NSpace.md)
        .padding(.bottom, NSpace.md)
    }

    // MARK: Stage bar

    // MARK: Thread

    @ViewBuilder
    private func thread(vm: SynthesisVM) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: NSpace.xxl) {
                    if vm.turns.isEmpty { intro }
                    ForEach(vm.turns) { turn in
                        turnView(turn, isLast: turn.id == vm.turns.last?.id, vm: vm)
                            .id(turn.id)
                    }
                    if case .failed(let msg) = vm.stage { errorPanel(msg) }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, NSpace.xl)
                .padding(.top, NSpace.md)
                .padding(.bottom, NSpace.xxl)
            }
            .scrollIndicators(.hidden)
            .onChange(of: vm.turns.count) { _, _ in
                withAnimation(.nEaseOutQuint) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: vm.stage) { _, new in
                if new == .done { withAnimation(.nEaseOutQuint) { proxy.scrollTo("bottom", anchor: .bottom) } }
            }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: NSpace.sm) {
            Text("// answers ground in your atoms.")
                .font(NFont.mono(11)).foregroundStyle(NSColorToken.textGhost)
            Text("// ask a follow-up to go deeper — context carries.")
                .font(NFont.mono(11)).foregroundStyle(NSColorToken.textGhost.opacity(0.6))
        }
        .padding(.top, NSpace.lg)
    }

    @ViewBuilder
    private func turnView(_ turn: SynthesisVM.Turn, isLast: Bool, vm: SynthesisVM) -> some View {
        VStack(alignment: .leading, spacing: NSpace.md) {
            HStack(alignment: .firstTextBaseline, spacing: NSpace.sm) {
                Text("//").font(NFont.mono(12)).foregroundStyle(NSColorToken.Phos.cyan.opacity(0.7))
                Text(turn.question)
                    .font(NFont.detailBody(16)).foregroundStyle(NSColorToken.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if turn.answer.isEmpty, isLast, vm.isStreaming {
                HStack(spacing: NSpace.sm) {
                    Circle().fill(NSColorToken.Phos.blue).frame(width: 5, height: 5).opacity(0.8)
                    Text("// \(stageLabel(for: vm.stage) ?? "thinking")…")
                        .font(NFont.mono(10)).foregroundStyle(NSColorToken.textTertiary)
                }
                .transition(.opacity)
            } else if !turn.answer.isEmpty {
                answerText(turn.answer)
                confidenceBadge(turn.confidence)
                if !turn.citations.isEmpty { citationRow(turn.citations) }
            }
        }
    }

    private func confidenceBadge(_ c: SynthesisVM.Confidence) -> some View {
        let color: Color
        switch c {
        case .high:       color = NSColorToken.Phos.green
        case .medium:     color = NSColorToken.Phos.cyan
        case .low:        color = NSColorToken.Phos.amber
        case .ungrounded: color = NSColorToken.Phos.orange
        }
        return HStack(spacing: NSpace.xs) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text("// \(c.label)").font(NFont.monoSmall(10)).foregroundStyle(color.opacity(0.9))
        }
        .accessibilityLabel("Confidence: \(c.label)")
    }

    private func citationRow(_ cites: [SynthesisVM.Citation]) -> some View {
        VStack(alignment: .leading, spacing: NSpace.sm) {
            Text("// grounded in")
                .font(NFont.mono(10)).foregroundStyle(NSColorToken.textTertiary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: NSpace.md) {
                    ForEach(cites) { c in
                        citationChip(c)
                            .onTapGesture { if let atom = store.atoms[c.id] { onPickAtom(atom) } }
                    }
                }
                .padding(.bottom, NSpace.xs)
            }
        }
        .padding(.top, NSpace.xs)
    }

    private func stageLabel(for stage: SynthesisVM.Stage) -> String? {
        switch stage {
        case .embedding:    "embedding query"
        case .retrieving:   "searching vault"
        case .synthesizing: "synthesizing"
        default: nil
        }
    }

    // MARK: Answer

    @ViewBuilder
    private func answerText(_ answer: String) -> some View {
        if let attr = try? AttributedString(
            markdown: answer,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            Text(attr)
                .font(NFont.detailBody(17))
                .foregroundStyle(NSColorToken.textPrimary)
                .lineSpacing(4)
                .textSelection(.enabled)
        } else {
            Text(answer)
                .font(NFont.detailBody(17))
                .foregroundStyle(NSColorToken.textPrimary)
                .lineSpacing(4)
                .textSelection(.enabled)
        }
    }

    private func errorPanel(_ msg: String) -> some View {
        VStack(alignment: .leading, spacing: NSpace.xs) {
            Text("// failed")
                .font(NFont.mono(10))
                .foregroundStyle(NSColorToken.Phos.orange)
            Text(msg)
                .font(NFont.body(14))
                .foregroundStyle(NSColorToken.textSecondary)
        }
        .padding(NSpace.md)
        .background(NSColorToken.inkRaised)
        .overlay(Rectangle().stroke(NSColorToken.Phos.orange.opacity(0.4), lineWidth: 0.5))
    }

    // MARK: Citation chip

    private func citationChip(_ c: SynthesisVM.Citation) -> some View {
        let atom = store.atoms[c.id]
        return VStack(alignment: .leading, spacing: NSpace.xs) {
            HStack(spacing: NSpace.xs) {
                if let atom {
                    AtomDot(type: atom.type, size: 6)
                }
                Text(relevanceLabel(c.score))
                    .font(NFont.mono(9))
                    .foregroundStyle(NSColorToken.textTertiary)
            }
            Text(c.snippet)
                .font(NFont.body(13))
                .foregroundStyle(NSColorToken.textSecondary)
                .lineLimit(4)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 220, alignment: .topLeading)
        .padding(NSpace.md)
        .background(NSColorToken.inkRaised)
        .overlay(Rectangle().stroke(NSColorToken.textGhost.opacity(0.25), lineWidth: 0.5))
    }

    // MARK: Helpers

    private func close() {
        vm?.cancel()
        onDismiss()
    }

    private func relevanceLabel(_ score: Double) -> String {
        switch score {
        case 0.85...: return "// strong"
        case 0.70...: return "// related"
        default:      return "// nearby"
        }
    }
}
