#if os(macOS)
import SwiftUI

// ─── MacSynthesisView ────────────────────────────────────────────────────────
//
// Synthesis panel for the Mac detail column.
// Reuses SynthesisVM — same SSE stream, same stage machine.
//
// Layout:
//   ┌─ header: // synthesize
//   ├─ question field (TextEditor w/ ⌘↩ to submit)
//   ├─ stage bar (streaming only)
//   ├─ answer area (plain text → markdown on done)
//   └─ citation chips (when present)

struct MacSynthesisView: View {
    let store: AtomStore
    let backend: NousBackendClient

    @State private var vm: SynthesisVM
    @FocusState private var focus: Bool

    init(store: AtomStore, backend: NousBackendClient) {
        self.store   = store
        self.backend = backend
        let userID   = AuthClient.shared.session?.userID ?? AppEnv.localUserID
        _vm = State(initialValue: SynthesisVM(backend: backend, userID: userID))
    }

    var body: some View {
        ZStack(alignment: .top) {
            synthesisBackdrop

            VStack(spacing: 0) {
                header
                Divider()
                    .overlay(NSColorToken.Phos.violet.opacity(0.20))
                questionArea
                stageBar
                answerArea
                if !vm.citations.isEmpty { citationStrip }
            }
        }
        .background(NSColorToken.inkVoid)
        .onDisappear { vm.cancel() }
        .task { focus = true }
    }

    // MARK: – Backdrop

    private var synthesisBackdrop: some View {
        ZStack {
            RadialGradient(
                colors: [NSColorToken.Phos.violet.opacity(0.14), .clear],
                center: UnitPoint(x: 0.5, y: 0.0),
                startRadius: 0,
                endRadius: 420
            )
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    // MARK: – Header

    private var header: some View {
        HStack {
            HStack(spacing: NSpace.sm) {
                Circle()
                    .fill(NSColorToken.Phos.violet.opacity(0.70))
                    .frame(width: 5, height: 5)
                Text("// synthesize")
                    .font(NFont.mono(12))
                    .foregroundStyle(NSColorToken.Phos.violet.opacity(0.80))
            }
            Spacer()
            if vm.isStreaming {
                Button("// cancel") { vm.cancel() }
                    .font(NFont.mono(11))
                    .foregroundStyle(NSColorToken.textGhost)
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, NSpace.xl)
        .padding(.vertical, NSpace.md)
    }

    // MARK: – Question area

    private var questionArea: some View {
        VStack(alignment: .leading, spacing: NSpace.sm) {
            ZStack(alignment: .topLeading) {
                if vm.question.isEmpty {
                    Text("// ask anything about your atoms...")
                        .font(NFont.mono(13))
                        .foregroundStyle(NSColorToken.textGhost.opacity(0.40))
                        .allowsHitTesting(false)
                        .padding(.top, 2)
                        .padding(.leading, 2)
                }
                TextEditor(text: $vm.question)
                    .font(NFont.mono(13))
                    .foregroundStyle(NSColorToken.textPrimary)
                    .scrollContentBackground(.hidden)
                    .focused($focus)
                    .frame(minHeight: 60, maxHeight: 120)
                    .onSubmit {
                        if vm.canSubmit { vm.submit() }
                    }
            }

            HStack {
                Spacer()
                Button("// ask") {
                    vm.submit()
                }
                .font(NFont.mono(12))
                .foregroundStyle(vm.canSubmit
                    ? NSColorToken.Phos.violet
                    : NSColorToken.textGhost)
                .buttonStyle(.plain)
                .disabled(!vm.canSubmit)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(.horizontal, NSpace.xl)
        .padding(.top, NSpace.md)
        .padding(.bottom, NSpace.sm)
    }

    // MARK: – Stage bar

    @ViewBuilder
    private var stageBar: some View {
        if vm.isStreaming {
            HStack(spacing: NSpace.sm) {
                ProgressView()
                    .scaleEffect(0.6)
                    .tint(NSColorToken.Phos.violet)
                Text(stageLabel)
                    .font(NFont.mono(10))
                    .foregroundStyle(NSColorToken.Phos.violet.opacity(0.65))
                    .contentTransition(.opacity)
                    .animation(.nEaseOutQuint, value: stageLabel)
                Spacer()
            }
            .padding(.horizontal, NSpace.xl)
            .padding(.vertical, NSpace.sm)
            .transition(.opacity)
        }
    }

    private var stageLabel: String {
        switch vm.stage {
        case .embedding:   return "// embedding query"
        case .retrieving:  return "// searching knowledge graph"
        case .synthesizing:return "// synthesizing answer"
        case .streaming:   return "// streaming"
        default:           return ""
        }
    }

    // MARK: – Answer area

    @ViewBuilder
    private var answerArea: some View {
        if !vm.answer.isEmpty {
            ScrollView {
                Group {
                    if case .done = vm.stage {
                        MarkdownView(
                            text: vm.answer,
                            atomID: nil,
                            store: store,
                            tint: NSColorToken.Phos.violet
                        )
                    } else {
                        Text(vm.answer)
                            .font(NFont.detailBody(15))
                    }
                }
                .foregroundStyle(NSColorToken.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, NSpace.xl)
                .padding(.vertical, NSpace.md)
            }
            .transition(.opacity)
        } else if case .failed(let msg) = vm.stage {
            Text("// \(msg)")
                .font(NFont.mono(11))
                .foregroundStyle(NSColorToken.Phos.orange.opacity(0.70))
                .padding(.horizontal, NSpace.xl)
                .padding(.vertical, NSpace.md)
        } else if case .idle = vm.stage {
            Spacer()
        }
    }

    // MARK: – Citation strip

    private var citationStrip: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(NSColorToken.textGhost.opacity(0.10))
                .frame(height: 0.5)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: NSpace.md) {
                    Text("// sources")
                        .font(NFont.mono(10))
                        .foregroundStyle(NSColorToken.textGhost)

                    ForEach(vm.citations) { citation in
                        citationChip(citation)
                    }
                }
                .padding(.horizontal, NSpace.xl)
                .padding(.vertical, NSpace.md)
            }
        }
    }

    private func citationChip(_ c: SynthesisVM.Citation) -> some View {
        HStack(spacing: NSpace.xs) {
            Circle()
                .fill(NSColorToken.Phos.violet.opacity(0.55))
                .frame(width: 5, height: 5)
            Text(c.snippet)
                .font(NFont.mono(11))
                .foregroundStyle(NSColorToken.textSecondary)
                .lineLimit(1)
                .frame(maxWidth: 200)
                .truncationMode(.tail)
        }
        .padding(.horizontal, NSpace.sm)
        .padding(.vertical, NSpace.xs)
        .background(NSColorToken.inkRaised)
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .strokeBorder(NSColorToken.Phos.violet.opacity(0.18), lineWidth: 0.5)
        )
    }
}

// MARK: – MarkdownView nil-atomID overload

private extension MarkdownView {
    init(text: String, atomID: UUID?, store: AtomStore, tint: Color) {
        self.init(text: text, atomID: atomID ?? UUID(), store: store, tint: tint)
    }
}

#endif
