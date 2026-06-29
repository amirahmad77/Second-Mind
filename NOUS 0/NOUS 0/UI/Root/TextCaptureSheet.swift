import SwiftUI

struct TextCaptureSheet: View {
    let store: AtomStore
    let onDismiss: () -> Void
    var onSaved: (() -> Void)? = nil
    var onOpenAtom: ((AtomSnapshot) -> Void)? = nil

    @AppStorage("nous.captureDraft") private var persistedDraft = ""
    @State private var buffer: String = ""
    @State private var hintType: AtomType = .thought
    @State private var similar: AtomSnapshot?
    @FocusState private var focus: Bool

    private var cardAccent: Color { hintType.phosphor }

    var body: some View {
        ZStack {
            NSColorToken.inkScrim.ignoresSafeArea()
                .onTapGesture { handleBackdropTap() }

            VStack(spacing: 0) {
                Spacer()

                VStack(alignment: .leading, spacing: 0) {

                    // ── Writing surface ──────────────────────────────────────
                    // No header above it. The editor IS the sheet.
                    ZStack(alignment: .topLeading) {
                        if buffer.isEmpty {
                            Text("// \(hintType.rawValue)")
                                .nDynamicBody(18)
                                .foregroundStyle(NSColorToken.textGhost.opacity(0.40))
                                .allowsHitTesting(false)
                                .padding(.top, 8)
                                .padding(.leading, 5)
                                .contentTransition(.opacity)
                                .animation(.nEaseOutQuint, value: hintType)
                        }
                        TextEditor(text: $buffer)
                            .nDynamicBody(18)
                            .foregroundStyle(NSColorToken.textPrimary)
                            .scrollContentBackground(.hidden)
                            .focused($focus)
                            .frame(minHeight: 160, maxHeight: 300)
                    }
                    .padding(.horizontal, NSpace.xl)
                    .padding(.top, NSpace.xl)
                    .padding(.bottom, NSpace.sm)

                    // ── "You already know this" — capture-time near-match ─────
                    if let similar {
                        Button {
                            onOpenAtom?(similar)
                            onDismiss()
                        } label: {
                            HStack(spacing: NSpace.sm) {
                                Text("≈ similar")
                                    .font(NFont.monoSmall(10))
                                    .foregroundStyle(NSColorToken.Phos.amber.opacity(0.85))
                                Text(similar.oneLiner)
                                    .font(NFont.mono(11))
                                    .foregroundStyle(NSColorToken.textSecondary)
                                    .lineLimit(1).truncationMode(.tail)
                                Spacer(minLength: 0)
                                if onOpenAtom != nil {
                                    Text("open →").font(NFont.monoSmall(10))
                                        .foregroundStyle(NSColorToken.textGhostDim)
                                }
                            }
                            .padding(.horizontal, NSpace.xl)
                            .padding(.vertical, NSpace.sm)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(onOpenAtom == nil)
                        .transition(.opacity)
                        .accessibilityLabel("Similar existing atom: \(similar.oneLiner)")
                    }

                    // ── Action row ───────────────────────────────────────────
                    // Lives near the keyboard — minimal thumb travel.
                    // Left: live type indicator (phosphor dot + label).
                    // Right: discard (fades in when there's a draft) + save.
                    HStack(alignment: .center, spacing: 0) {
                        // Live type hint — replaces the old header "// capture".
                        // Dot color shifts with classification (purely visual).
                        HStack(spacing: NSpace.sm) {
                            Circle()
                                .fill(cardAccent.opacity(hasDraft ? 0.80 : 0.30))
                                .frame(width: 5, height: 5)
                            Text("// \(hintType.rawValue)")
                                .font(NFont.mono(11))
                                .foregroundStyle(cardAccent.opacity(hasDraft ? 0.65 : 0.30))
                                .contentTransition(.opacity)
                        }
                        .animation(.nEaseOutQuint, value: hintType)

                        Spacer(minLength: 0)

                        HStack(spacing: NSpace.xl) {
                            if hasDraft {
                                Button("discard") { discardDraft() }
                                    .font(NFont.mono(12))
                                    .foregroundStyle(NSColorToken.textGhost)
                                    .frame(minWidth: 44, minHeight: 44)
                                    .contentShape(Rectangle())
                                    .transition(.opacity.combined(with: .move(edge: .trailing)))
                                    .accessibilityLabel("Discard draft")
                                    .accessibilityHint("Clears the current draft")
                            }
                            Button("save") { dismiss(save: true) }
                                .font(NFont.mono(12))
                                .foregroundStyle(hasDraft ? cardAccent : NSColorToken.textGhost)
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                                .disabled(!hasDraft)
                                .accessibilityLabel("Save atom")
                                .accessibilityHint("Saves and classifies your note")
                        }
                        .animation(.nEaseOutQuint, value: hasDraft)
                    }
                    .padding(.horizontal, NSpace.xl)
                    .padding(.vertical, NSpace.lg)

                    // Draft hint — only when draft exists and user might mis-tap
                    if hasDraft {
                        Text("// tap outside to keep draft")
                            .font(NFont.mono(10))
                            .foregroundStyle(NSColorToken.textGhost.opacity(0.55))
                            .padding(.horizontal, NSpace.xl)
                            .padding(.bottom, NSpace.md)
                            .transition(.opacity)
                    }
                }
                .background(
                    NSColorToken.inkRaised
                        .overlay(cardAccent.opacity(0.04))
                        .animation(.nEaseOutQuint, value: hintType)
                )
                // Phosphor hairline at top of card — shifts with live type
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(cardAccent.opacity(0.35))
                        .frame(height: 0.75)
                        .animation(.nEaseOutQuint, value: hintType)
                }
            }
        }
        .task {
            if buffer.isEmpty { buffer = persistedDraft }
            focus = true
        }
        // Live type classification: 280ms debounce per keystroke
        .task(id: buffer) {
            let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                withAnimation(.nEaseOutQuint) { hintType = .thought; similar = nil }
                return
            }
            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled else { return }
            let detected = classify(trimmed)
            if detected != hintType {
                withAnimation(.nEaseOutQuint) { hintType = detected }
            }
            let match = store.lexicalSimilar(to: trimmed, limit: 1).first
            if match?.id != similar?.id {
                withAnimation(.nEaseOutQuint) { similar = match }
            }
        }
        .onChange(of: buffer) { _, new in persistedDraft = new }
        .onSubmit { dismiss(save: true) }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                LinkPickerBar(
                    text: $buffer,
                    store: store,
                    onPicked: { focus = true },
                    onCancel: { focus = true }
                )
                MarkdownToolbar(text: $buffer)
            }
        }
    }

    // MARK: - Helpers

    private var hasDraft: Bool {
        !buffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func handleBackdropTap() {
        if hasDraft { focus = false } else { discardDraft() }
    }

    private func discardDraft() {
        persistedDraft = ""
        buffer = ""
        onDismiss()
    }

    private func dismiss(save: Bool) {
        let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if save && !trimmed.isEmpty {
            _ = store.capture(raw: trimmed, type: .thought)
            Haptics.shared.saveConfirm()
            persistedDraft = ""
            onSaved?()
        }
        onDismiss()
    }

    private func classify(_ s: String) -> AtomType {
        let lc = s.lowercased()
        if s.hasPrefix("http://") || s.hasPrefix("https://") { return .reference }
        if lc.hasPrefix("todo") || lc.hasPrefix("- [ ]")
            || lc.contains("need to ") || lc.contains("should ") || lc.contains("must ") { return .task }
        if lc.contains("?") { return .question }
        if lc.contains("meeting") || lc.contains("mtg") { return .meeting }
        if lc.hasPrefix("decision") || lc.contains("decided") { return .decision }
        return .thought
    }
}
