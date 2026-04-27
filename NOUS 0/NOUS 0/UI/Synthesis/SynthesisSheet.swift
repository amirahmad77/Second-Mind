import SwiftUI

/// Synthesis surface — appears on swipe-down from Orb (PRD §2.4).
///
/// Layout:
///   ┌─ header bar: // synthesize · close
///   ├─ question field (TextEditor, monospaced prompt)
///   ├─ stage bar (subtle, only while streaming)
///   ├─ answer (progressive, scrollable, markdown-rendered on done)
///   └─ citation chips (horizontal scroll, tap → open atom)
///
/// Stream cancellable via close (PRD: "user can interrupt").
struct SynthesisSheet: View {
    let store: AtomStore
    let backend: NousBackendClient
    let onDismiss: () -> Void
    let onPickAtom: (AtomSnapshot) -> Void

    @State private var vm: SynthesisVM
    @FocusState private var focus: Bool

    init(store: AtomStore,
         backend: NousBackendClient,
         userID: UUID,
         onDismiss: @escaping () -> Void,
         onPickAtom: @escaping (AtomSnapshot) -> Void) {
        self.store = store
        self.backend = backend
        self.onDismiss = onDismiss
        self.onPickAtom = onPickAtom
        _vm = State(initialValue: SynthesisVM(backend: backend, userID: userID))
    }

    var body: some View {
        ZStack(alignment: .top) {
            backdrop

            VStack(spacing: 0) {
                header
                Divider()
                    .frame(height: 0.5)
                    .overlay(NSColorToken.textGhost.opacity(0.35))
                questionArea
                stageBar
                answerArea
                if !vm.citations.isEmpty {
                    citationStrip
                }
            }
        }
        .background(NSColorToken.inkVoid.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .task { focus = true }
        .onDisappear { vm.cancel() }
    }

    // MARK: Backdrop — synthesis blue halo

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
            if vm.isStreaming {
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

    private var questionArea: some View {
        VStack(alignment: .leading, spacing: NSpace.sm) {
            Text("// ask your mind")
                .font(NFont.mono(10))
                .foregroundStyle(NSColorToken.textGhost)
            HStack(alignment: .top, spacing: NSpace.md) {
                TextField("",
                          text: $vm.question,
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

    @ViewBuilder private var stageBar: some View {
        if vm.isStreaming, let label = stageLabel(for: vm.stage) {
            HStack(spacing: NSpace.sm) {
                Circle()
                    .fill(NSColorToken.Phos.blue)
                    .frame(width: 5, height: 5)
                    .opacity(0.8)
                Text("// \(label)")
                    .font(NFont.mono(10))
                    .foregroundStyle(NSColorToken.textTertiary)
                if let detail = vm.stageDetail {
                    Text("· \(detail)")
                        .font(NFont.mono(10))
                        .foregroundStyle(NSColorToken.textGhost)
                }
                Spacer()
            }
            .padding(.horizontal, NSpace.xl)
            .padding(.bottom, NSpace.sm)
            .transition(.opacity)
        }
    }

    private func stageLabel(for stage: SynthesisVM.Stage) -> String? {
        switch stage {
        case .embedding:    "embedding query"
        case .retrieving:   "retrieving atoms"
        case .synthesizing: "synthesizing"
        case .streaming:    "writing"
        default: nil
        }
    }

    // MARK: Answer

    @ViewBuilder private var answerArea: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NSpace.lg) {
                if vm.answer.isEmpty {
                    answerPlaceholder
                } else {
                    answerText
                }
                if case .failed(let msg) = vm.stage {
                    errorPanel(msg)
                }
            }
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, NSpace.xl)
            .padding(.top, NSpace.md)
            .padding(.bottom, NSpace.xxl)
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder private var answerPlaceholder: some View {
        VStack(alignment: .leading, spacing: NSpace.md) {
            if vm.stage == .idle {
                Text("// answers ground in your atoms.")
                    .font(NFont.mono(11))
                    .foregroundStyle(NSColorToken.textGhost)
                Text("// citations appear as chips below.")
                    .font(NFont.mono(11))
                    .foregroundStyle(NSColorToken.textGhost.opacity(0.6))
            } else if vm.isStreaming {
                Text("// thinking…")
                    .font(NFont.mono(11))
                    .foregroundStyle(NSColorToken.Phos.blue.opacity(0.7))
            }
        }
    }

    @ViewBuilder private var answerText: some View {
        // While streaming, render plain text (markdown isn't progressive-friendly).
        // On `.done`, swap to AttributedString with markdown for headings/bullets/emphasis.
        if vm.stage == .done, let attr = try? AttributedString(
            markdown: vm.answer,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            Text(attr)
                .font(NFont.detailBody(17))
                .foregroundStyle(NSColorToken.textPrimary)
                .lineSpacing(4)
                .textSelection(.enabled)
        } else {
            Text(vm.answer)
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

    // MARK: Citation strip

    private var citationStrip: some View {
        VStack(alignment: .leading, spacing: NSpace.sm) {
            Divider()
                .frame(height: 0.5)
                .overlay(NSColorToken.textGhost.opacity(0.25))
            Text("// grounded in")
                .font(NFont.mono(10))
                .foregroundStyle(NSColorToken.textTertiary)
                .padding(.horizontal, NSpace.xl)
                .padding(.top, NSpace.md)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: NSpace.md) {
                    ForEach(vm.citations) { c in
                        citationChip(c)
                            .onTapGesture {
                                if let atom = store.atoms[c.id] {
                                    onPickAtom(atom)
                                }
                            }
                    }
                }
                .padding(.horizontal, NSpace.xl)
                .padding(.bottom, NSpace.lg)
            }
        }
        .background(NSColorToken.inkPaper.opacity(0.55))
    }

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

    private func close() {
        vm.cancel()
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
