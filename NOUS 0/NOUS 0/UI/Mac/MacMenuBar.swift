#if os(macOS)
import SwiftUI
import SwiftData

// ─── MacMenuBarContent ────────────────────────────────────────────────────────
//
// Popover-style menu bar window.
// Shown when user clicks the menu bar extra dot.
//
// Contents:
//   • Quick capture field (immediate, no nav needed)
//   • Recent atoms (last 5)
//   • Open main window button

struct MacMenuBarContent: View {
    let auth: AuthClient

    @Environment(\.modelContext) private var ctx
    @State private var captureText = ""
    @State private var store: AtomStore?
    @State private var gemini    = GeminiClient()
    @State private var supabase  = SupabaseClient()
    @State private var sync: SyncDaemon?
    @FocusState private var focus: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
                .overlay(NSColorToken.textGhost.opacity(0.12))
            captureField
            if let store, !store.ordered.isEmpty {
                Divider()
                    .overlay(NSColorToken.textGhost.opacity(0.10))
                recentAtoms(store)
            }
            Divider()
                .overlay(NSColorToken.textGhost.opacity(0.10))
            footer
        }
        .frame(width: 320)
        .background(NSColorToken.inkRaised)
        .task { bootstrapIfNeeded() }
        .task { focus = true }
    }

    // MARK: – Header

    private var header: some View {
        HStack {
            HStack(spacing: NSpace.xs) {
                Circle()
                    .fill(NSColorToken.Phos.cyan.opacity(0.70))
                    .frame(width: 5, height: 5)
                Text("// nous")
                    .font(NFont.mono(12))
                    .foregroundStyle(NSColorToken.textSecondary)
            }
            Spacer()
            Text(auth.isAuthenticated ? "// online" : "// offline")
                .font(NFont.mono(10))
                .foregroundStyle(auth.isAuthenticated
                    ? NSColorToken.Phos.green.opacity(0.60)
                    : NSColorToken.textGhost)
        }
        .padding(.horizontal, NSpace.md)
        .padding(.vertical, NSpace.sm)
    }

    // MARK: – Capture field

    private var captureField: some View {
        HStack(spacing: NSpace.sm) {
            TextField("", text: $captureText, prompt:
                Text("// capture a thought...")
                    .font(NFont.mono(12))
                    .foregroundStyle(NSColorToken.textGhost.opacity(0.45))
            )
            .font(NFont.mono(12))
            .foregroundStyle(NSColorToken.textPrimary)
            .textFieldStyle(.plain)
            .focused($focus)
            .onSubmit { quickCapture() }

            if !captureText.isEmpty {
                Button { quickCapture() } label: {
                    Text("↩")
                        .font(NFont.mono(12))
                        .foregroundStyle(NSColorToken.Phos.cyan.opacity(0.80))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, NSpace.md)
        .padding(.vertical, NSpace.sm)
        .background(NSColorToken.inkVoid.opacity(0.50))
    }

    // MARK: – Recent atoms

    private func recentAtoms(_ store: AtomStore) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("// recent")
                .font(NFont.mono(10))
                .foregroundStyle(NSColorToken.textGhost)
                .padding(.horizontal, NSpace.md)
                .padding(.top, NSpace.sm)
                .padding(.bottom, NSpace.xs)

            ForEach(store.ordered.prefix(5)) { atom in
                HStack(spacing: NSpace.sm) {
                    Circle()
                        .fill(atom.type.phosphor)
                        .frame(width: 5, height: 5)
                    Text(atom.oneLiner)
                        .font(NFont.body(12))
                        .foregroundStyle(NSColorToken.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    Text(atom.createdAt.formatted(date: .omitted, time: .shortened))
                        .font(NFont.mono(10))
                        .foregroundStyle(NSColorToken.textGhost)
                        .monospacedDigit()
                }
                .padding(.horizontal, NSpace.md)
                .padding(.vertical, NSpace.xs)
                .contentShape(Rectangle())
            }
        }
        .padding(.bottom, NSpace.xs)
    }

    // MARK: – Footer

    private var footer: some View {
        HStack {
            Button("Open NOUS") {
                NSApplication.shared.activate(ignoringOtherApps: true)
                // Bring main window to front
                for win in NSApplication.shared.windows {
                    if win.identifier?.rawValue == "main" { win.makeKeyAndOrderFront(nil) }
                }
            }
            .font(NFont.mono(11))
            .foregroundStyle(NSColorToken.textSecondary)
            .buttonStyle(.plain)

            Spacer()

            Button("Quit") { NSApplication.shared.terminate(nil) }
                .font(NFont.mono(11))
                .foregroundStyle(NSColorToken.textGhost)
                .buttonStyle(.plain)
        }
        .padding(.horizontal, NSpace.md)
        .padding(.vertical, NSpace.sm)
    }

    // MARK: – Actions

    private func quickCapture() {
        let trimmed = captureText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let store else { return }
        _ = store.capture(raw: trimmed, type: .thought)
        NousLogger.info("mac.menubar", "quick capture", ["len": trimmed.count])
        captureText = ""
    }

    private func bootstrapIfNeeded() {
        guard store == nil, auth.isAuthenticated else { return }
        let s = SyncDaemon(context: ctx, supabase: supabase, gemini: gemini)
        let st = AtomStore(context: ctx, sync: s, gemini: gemini)
        st.bootstrap()
        s.onRemoteEvent = { [weak st] e in st?.applyRemoteEvent(e) }
        s.bootstrap()
        store = st
        sync  = s
    }
}

#endif
