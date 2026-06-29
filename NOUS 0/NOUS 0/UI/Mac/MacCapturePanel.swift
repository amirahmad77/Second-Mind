#if os(macOS)
import SwiftUI

// ─── MacCapturePanel ─────────────────────────────────────────────────────────
//
// Floating capture panel. Appears on:
//   • ⌘N from main window
//   • Global hotkey ⌘⌥Space (registered via NSEvent global monitor)
//   • MenuBarExtra quick capture button
//
// Layout mirrors iOS TextCaptureSheet but tuned for Mac:
//   - Wider (480pt), taller minimum (180pt editor)
//   - Keyboard commit: ⌘Return to save, Esc to discard draft
//   - Live type classification (same 280ms debounce as iOS)
//   - No modal chrome — just a floating card on inkVoid
//
// Dismiss behaviour:
//   - With draft: Esc keeps draft (same AppStorage key as iOS for continuity)
//   - Without draft: Esc closes immediately

struct MacCapturePanel: View {
    let store: AtomStore
    let onDismiss: () -> Void
    var onOpenAtom: ((AtomSnapshot) -> Void)? = nil

    @AppStorage("nous.captureDraft") private var persistedDraft = ""
    @State private var buffer: String = ""
    @State private var hintType: AtomType = .thought
    @State private var similar: AtomSnapshot?
    @FocusState private var focus: Bool

    private var cardAccent: Color { hintType.phosphor }
    private var hasDraft: Bool {
        !buffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            // Top bar: type hint
            HStack(spacing: NSpace.sm) {
                Circle()
                    .fill(cardAccent.opacity(hasDraft ? 0.80 : 0.30))
                    .frame(width: 5, height: 5)
                Text("// \(hintType.rawValue)")
                    .font(NFont.mono(11))
                    .foregroundStyle(cardAccent.opacity(hasDraft ? 0.65 : 0.30))
                    .contentTransition(.opacity)
                    .animation(.nEaseOutQuint, value: hintType)

                Spacer(minLength: 0)

                Text("⌘↩ save · ⎋ dismiss")
                    .font(NFont.mono(10))
                    .foregroundStyle(NSColorToken.textGhost.opacity(0.40))
            }
            .padding(.horizontal, NSpace.xl)
            .padding(.top, NSpace.lg)
            .padding(.bottom, NSpace.sm)

            // Phosphor hairline
            Rectangle()
                .fill(cardAccent.opacity(0.25))
                .frame(height: 0.5)
                .animation(.nEaseOutQuint, value: hintType)

            // Writing surface
            ZStack(alignment: .topLeading) {
                if buffer.isEmpty {
                    Text("// \(hintType.rawValue)")
                        .font(NFont.mono(14))
                        .foregroundStyle(NSColorToken.textGhost.opacity(0.35))
                        .allowsHitTesting(false)
                        .padding(.top, 10)
                        .padding(.leading, 6)
                        .contentTransition(.opacity)
                        .animation(.nEaseOutQuint, value: hintType)
                }
                TextEditor(text: $buffer)
                    .font(NFont.body(15))
                    .foregroundStyle(NSColorToken.textPrimary)
                    .scrollContentBackground(.hidden)
                    .focused($focus)
                    .frame(minHeight: 140, maxHeight: 280)
            }
            .padding(.horizontal, NSpace.xl)
            .padding(.top, NSpace.md)
            .padding(.bottom, NSpace.xs)

            // Link picker (shown when [[ is active)
            LinkPickerBar(
                text: $buffer,
                store: store,
                onPicked: { focus = true },
                onCancel:  { focus = true }
            )
            .padding(.horizontal, NSpace.xl)

            // Markdown toolbar
            MarkdownToolbar(text: $buffer)
                .padding(.horizontal, NSpace.xl)
                .padding(.bottom, NSpace.sm)

            // "You already know this" — capture-time near-match
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

            // Action row
            HStack(spacing: NSpace.xl) {
                if hasDraft {
                    Button("discard") { discardDraft() }
                        .font(NFont.mono(12))
                        .foregroundStyle(NSColorToken.textGhost)
                        .buttonStyle(.plain)
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
                Spacer(minLength: 0)
                Button("save") { save() }
                    .font(NFont.mono(12))
                    .foregroundStyle(hasDraft ? cardAccent : NSColorToken.textGhost)
                    .buttonStyle(.plain)
                    .disabled(!hasDraft)
                    .keyboardShortcut(.return, modifiers: .command)
            }
            .animation(.nEaseOutQuint, value: hasDraft)
            .padding(.horizontal, NSpace.xl)
            .padding(.bottom, NSpace.lg)

            // Draft hint
            if hasDraft {
                Text("// ⎋ keeps draft open")
                    .font(NFont.mono(10))
                    .foregroundStyle(NSColorToken.textGhost.opacity(0.45))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, NSpace.xl)
                    .padding(.bottom, NSpace.md)
                    .transition(.opacity)
            }
        }
        .background(NSColorToken.inkRaised)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(cardAccent.opacity(0.30))
                .frame(height: 0.75)
                .animation(.nEaseOutQuint, value: hintType)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(NSColorToken.textGhost.opacity(0.10), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.40), radius: 32, x: 0, y: 8)
        .frame(width: 480)
        .padding(NSpace.xl)
        // Live classification
        .task {
            if buffer.isEmpty { buffer = persistedDraft }
            focus = true
        }
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
        .onKeyPress(.escape) {
            handleEscape()
            return .handled
        }
    }

    // MARK: – Actions

    private func save() {
        let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        _ = store.capture(raw: trimmed, type: hintType)
        NousLogger.info("mac", "capture saved", ["len": trimmed.count, "type": hintType.rawValue])
        persistedDraft = ""
        buffer = ""
        onDismiss()
    }

    private func discardDraft() {
        persistedDraft = ""
        buffer = ""
        onDismiss()
    }

    private func handleEscape() {
        // With draft: keep draft, close panel
        // Without draft: just close
        if hasDraft { focus = false }
        onDismiss()
    }

    // MARK: – Classification (mirrors iOS TextCaptureSheet)

    private func classify(_ s: String) -> AtomType {
        let lc = s.lowercased()
        if s.hasPrefix("http://") || s.hasPrefix("https://")           { return .reference }
        if lc.hasPrefix("todo") || lc.hasPrefix("- [ ]")
            || lc.contains("need to ") || lc.contains("should ")
            || lc.contains("must ")                                     { return .task }
        if lc.contains("?")                                             { return .question }
        if lc.contains("meeting") || lc.contains("mtg")                { return .meeting }
        if lc.hasPrefix("decision") || lc.contains("decided")          { return .decision }
        return .thought
    }
}

// MARK: – Global hotkey registration

/// Call once at app launch. Registers ⌘⌥Space as a global capture shortcut.
/// Posts `.nousOpenCapture` notification which MacRootView listens to.
enum MacGlobalHotkey {
    static func register() {
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            // ⌘⌥Space: keyCode 49, flags must include both command + option
            guard event.keyCode == 49,
                  event.modifierFlags.contains([.command, .option]) else { return }
            DispatchQueue.main.async {
                NSApplication.shared.activate(ignoringOtherApps: true)
                NotificationCenter.default.post(name: .nousOpenCapture, object: nil)
            }
        }
    }
}

#endif
