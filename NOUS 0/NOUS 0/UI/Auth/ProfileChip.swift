import SwiftUI
import Combine
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#endif

/// Top-right account affordance. Tap = sheet w/ email + sign-out.
///
/// Design choices:
///   - 28pt circle, hairline phosphor border, mono first-letter glyph
///   - Avatar URL fetched async if available; falls back to initial
///   - Tap → minimal confirmation sheet (no menu, sheet preserves spatial model)
///   - Sign-out runs an explicit confirm (single irreversible action)
struct ProfileChip: View {
    @Bindable var auth: AuthClient
    /// Optional store used for whole-vault export. When nil, the export row is hidden.
    /// Lead wires this from RootView/MacRootView where the live `AtomStore` exists.
    var store: AtomStore? = nil
    @State private var showSheet = false

    var body: some View {
        Button {
            Haptics.shared.softTick()
            showSheet = true
        } label: {
            avatarGlyph
        }
        .buttonStyle(ChipPressStyle())
        .accessibilityLabel("account · \(auth.session?.email ?? "signed in")")
        .sheet(isPresented: $showSheet) {
            AccountSheet(auth: auth, store: store, onDismiss: { showSheet = false })
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(NSColorToken.inkPaper)
        }
    }

    @ViewBuilder
    private var avatarGlyph: some View {
        ZStack {
            Circle()
                .fill(NSColorToken.inkRaised)
                .overlay(Circle().stroke(NSColorToken.Phos.cyan.opacity(0.35), lineWidth: 0.5))
            // Always monogram — photographic avatars fight the kinetic-minimalism
            // aesthetic (only non-abstract pixel cluster on screen). Mono initial
            // in phos cyan keeps the register.
            initialGlyph
        }
        .frame(width: 28, height: 28)
        // Extend hit area to 44pt without changing the visual footprint
        .frame(width: 44, height: 44)
        .contentShape(Circle())
    }

    private var initialGlyph: some View {
        Text(initial)
            .font(NFont.mono(11))
            .foregroundStyle(NSColorToken.Phos.cyan)
            .textCase(.uppercase)
    }

    private var initial: String {
        let s = auth.session?.displayName?.first ?? auth.session?.email?.first
        return s.map(String.init) ?? "·"
    }
}

private struct AccountSheet: View {
    @Bindable var auth: AuthClient
    var store: AtomStore? = nil
    let onDismiss: () -> Void

    @State private var confirming = false
    @State private var signingOut = false
    @State private var confirmingDelete = false
    #if os(iOS) || os(visionOS)
    // iOS/visionOS entry point to the shared settings surface. macOS reaches
    // SettingsView via the ⌘, Settings scene, so it's not wired here.
    @State private var showSettings = false
    #endif
    @State private var deleting = false
    @State private var deleteError: String?
    @State private var showPair = false
    @AppStorage(SoundFX.enabledKey) private var soundEnabled: Bool = false
    @AppStorage(ProactiveSurface.enabledKey) private var proactiveEnabled: Bool = false
    @AppStorage(ProactiveSurface.hourKey)    private var proactiveHour: Int = 8

    var body: some View {
        VStack(alignment: .leading, spacing: NSpace.lg) {
            VStack(alignment: .leading, spacing: NSpace.xs) {
                Text("// signed in")
                    .font(NFont.mono(10))
                    .foregroundStyle(NSColorToken.textTertiary)
                    .textCase(.uppercase)
                    .tracking(0.10)
                if let name = auth.session?.displayName {
                    Text(name)
                        .font(NFont.body(17))
                        .foregroundStyle(NSColorToken.textPrimary)
                }
                if let email = auth.session?.email {
                    Text(email)
                        .font(NFont.mono(12))
                        .foregroundStyle(NSColorToken.textSecondary)
                }
            }

            #if os(iOS) || os(visionOS)
            // Settings → presents the shared SettingsView. macOS uses the ⌘,
            // Settings scene instead, so this row is iOS/visionOS-only.
            Button {
                Haptics.shared.softTick()
                showSettings = true
            } label: {
                HStack {
                    Text("settings")
                        .font(NFont.body(15))
                        .foregroundStyle(NSColorToken.textPrimary)
                    Spacer()
                    Text("→")
                        .font(NFont.mono(13))
                        .foregroundStyle(NSColorToken.Phos.cyan)
                }
                .frame(maxWidth: .infinity, minHeight: 44)
                .padding(.horizontal, NSpace.md)
                .background(NSColorToken.inkRaised)
                .overlay(Rectangle().stroke(NSColorToken.textGhost.opacity(0.45), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
            .accessibilityHint("Opens app settings")
            #endif

            Spacer(minLength: 0)

            // Sound toggle — TE-coded micro-audio cues.
            Toggle(isOn: $soundEnabled) {
                Text("sound")
                    .font(NFont.body(15))
                    .foregroundStyle(NSColorToken.textPrimary)
            }
            .tint(NSColorToken.Phos.cyan)
            .onChange(of: soundEnabled) { _, on in
                if on { SoundFX.shared.captureCommit() }   // demo cue
            }

            // Proactive surface — daily resurfaced atom from your past.
            VStack(alignment: .leading, spacing: NSpace.xs) {
                Toggle(isOn: $proactiveEnabled) {
                    Text("daily resurface")
                        .font(NFont.body(15))
                        .foregroundStyle(NSColorToken.textPrimary)
                }
                .tint(NSColorToken.Phos.cyan)
                .onChange(of: proactiveEnabled) { _, on in
                    Task { await ProactiveSurface.shared.setEnabled(on, store: nil) }
                }
                if proactiveEnabled {
                    HStack(spacing: NSpace.xs) {
                        Text("at")
                            .font(NFont.mono(11))
                            .foregroundStyle(NSColorToken.textGhost)
                        Picker("", selection: $proactiveHour) {
                            ForEach(0..<24, id: \.self) { h in
                                Text(String(format: "%02d:00", h))
                                    .font(NFont.mono(13))
                                    .tag(h)
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(NSColorToken.Phos.cyan)
                        .onChange(of: proactiveHour) { _, h in
                            Task { await ProactiveSurface.shared.setHour(h, store: nil) }
                        }
                    }
                }
            }

            // Sync diagnostic — visibility into the pull pipeline so the user
            // can spot user_id mismatches w/ the Chrome extension.
            SyncDiagnosticPanel()

            // Compose-from-atoms — drafts writing grounded in the user's notes.
            Button {
                Haptics.shared.softTick()
                onDismiss()
                NotificationCenter.default.post(name: .nousOpenCompose, object: nil)
            } label: {
                HStack {
                    Text("compose")
                        .font(NFont.body(15))
                        .foregroundStyle(NSColorToken.textPrimary)
                    Spacer()
                    Text("→")
                        .font(NFont.mono(13))
                        .foregroundStyle(NSColorToken.Phos.cyan)
                }
                .frame(maxWidth: .infinity, minHeight: 44)
                .padding(.horizontal, NSpace.md)
                .background(NSColorToken.inkRaised)
                .overlay(Rectangle().stroke(NSColorToken.textGhost.opacity(0.45), lineWidth: 0.5))
            }
            .buttonStyle(.plain)

            // Pair browser → opens 6-digit code sheet for the Chrome extension.
            Button {
                Haptics.shared.softTick()
                showPair = true
            } label: {
                HStack {
                    Text("pair browser")
                        .font(NFont.body(15))
                        .foregroundStyle(NSColorToken.textPrimary)
                    Spacer()
                    Text("→")
                        .font(NFont.mono(13))
                        .foregroundStyle(NSColorToken.Phos.cyan)
                }
                .frame(maxWidth: .infinity, minHeight: 44)
                .padding(.horizontal, NSpace.md)
                .background(NSColorToken.inkRaised)
                .overlay(Rectangle().stroke(NSColorToken.textGhost.opacity(0.45), lineWidth: 0.5))
            }
            .buttonStyle(.plain)

            // Export all notes — Markdown + JSON of the entire vault.
            if let store {
                exportAllRow(store: store)
            }

            // Two-step destructive action — Emil's "irreversible action confirms".
            if confirming {
                HStack(spacing: NSpace.sm) {
                    Button(action: cancel) {
                        Text("cancel")
                            .font(NFont.mono(13))
                            .foregroundStyle(NSColorToken.textSecondary)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(NSColorToken.inkRaised)
                            .overlay(Rectangle().stroke(NSColorToken.textGhost.opacity(0.3), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)

                    Button(action: confirmSignOut) {
                        HStack(spacing: NSpace.xs) {
                            if signingOut {
                                ProgressView().controlSize(.mini).tint(NSColorToken.Phos.orange)
                            }
                            Text(signingOut ? "// signing out…" : "confirm sign-out")
                                .font(NFont.mono(13))
                                .foregroundStyle(NSColorToken.Phos.orange)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(NSColorToken.inkRaised)
                        .overlay(Rectangle().stroke(NSColorToken.Phos.orange.opacity(0.55), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .disabled(signingOut)
                }
            } else {
                Button {
                    Haptics.shared.softTick()
                    withAnimation(.timingCurve(0.23, 1.0, 0.32, 1.0, duration: 0.22)) {
                        confirming = true
                    }
                } label: {
                    Text("sign out")
                        .font(NFont.body(15))
                        .foregroundStyle(NSColorToken.textPrimary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(NSColorToken.inkRaised)
                        .overlay(Rectangle().stroke(NSColorToken.textGhost.opacity(0.45), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
            }

            // Danger zone — account deletion (App Store 5.1.1).
            VStack(alignment: .leading, spacing: NSpace.xs) {
                Text("// danger zone")
                    .font(NFont.mono(10))
                    .tracking(1.4)
                    .textCase(.uppercase)
                    .foregroundStyle(NSColorToken.textGhost)
                if let err = deleteError {
                    Text(err)
                        .font(NFont.mono(10))
                        .foregroundStyle(NSColorToken.Phos.orange)
                        .lineLimit(2)
                }
                if confirmingDelete {
                    HStack(spacing: NSpace.sm) {
                        Button {
                            Haptics.shared.softTick()
                            withAnimation(.easeOut(duration: 0.18)) { confirmingDelete = false; deleteError = nil }
                        } label: {
                            Text("cancel")
                                .font(NFont.mono(13))
                                .foregroundStyle(NSColorToken.textSecondary)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(NSColorToken.inkRaised)
                                .overlay(Rectangle().stroke(NSColorToken.textGhost.opacity(0.3), lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)

                        Button {
                            Haptics.shared.heavyThud()
                            deleting = true
                            deleteError = nil
                            Task { @MainActor in
                                do {
                                    try await auth.deleteAccount()
                                    Haptics.shared.cancelCrash()
                                    onDismiss()
                                } catch {
                                    deleteError = error.localizedDescription
                                    deleting = false
                                    confirmingDelete = false
                                }
                            }
                        } label: {
                            HStack(spacing: NSpace.xs) {
                                if deleting { ProgressView().controlSize(.mini).tint(.red) }
                                Text(deleting ? "// deleting…" : "delete account")
                                    .font(NFont.mono(13))
                                    .foregroundStyle(.red)
                            }
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(NSColorToken.inkRaised)
                            .overlay(Rectangle().stroke(Color.red.opacity(0.55), lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                        .disabled(deleting)
                    }
                } else {
                    Button {
                        Haptics.shared.softTick()
                        withAnimation(.timingCurve(0.23, 1.0, 0.32, 1.0, duration: 0.22)) { confirmingDelete = true }
                    } label: {
                        Text("delete account")
                            .font(NFont.body(15))
                            .foregroundStyle(NSColorToken.textGhost)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(NSColorToken.inkRaised)
                            .overlay(Rectangle().stroke(NSColorToken.textGhost.opacity(0.30), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(NSpace.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(NSColorToken.inkPaper)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showPair) {
            PairBrowserSheet(userID: AppEnv.currentUserIDSync)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(NSColorToken.inkPaper)
        }
        #if os(iOS) || os(visionOS)
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(NSColorToken.inkPaper)
        }
        #endif
    }

    // MARK: – Export all notes

    @ViewBuilder
    private func exportAllRow(store: AtomStore) -> some View {
        let atoms = store.ordered
        #if os(iOS) || os(visionOS)
        // iOS: ShareLink of generated Markdown + JSON temp files.
        let stem = AtomExport.vaultFileStem()
        let mdURL = AtomExport.temporaryFile(name: "\(stem).md", contents: AtomExport.markdown(atoms))
        let jsonURL = AtomExport.temporaryFile(name: "\(stem).json", contents: AtomExport.json(atoms))
        let urls = [mdURL, jsonURL].compactMap { $0 }
        ShareLink(items: urls,
                  subject: Text("NOUS export"),
                  preview: { url in SharePreview(url.lastPathComponent, image: Image(systemName: "doc.text")) }) {
            exportRowLabel(count: atoms.count)
        }
        .buttonStyle(.plain)
        .disabled(atoms.isEmpty)
        .accessibilityLabel("Export all notes")
        .accessibilityHint("Shares your whole vault as Markdown and JSON")
        #else
        // macOS: NSSavePanel — Markdown default, JSON optional.
        Menu {
            Button("Markdown (.md)") { exportAll(atoms, asJSON: false) }
            Button("JSON (.json)")   { exportAll(atoms, asJSON: true) }
        } label: {
            exportRowLabel(count: atoms.count)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .disabled(atoms.isEmpty)
        .accessibilityLabel("Export all notes")
        #endif
    }

    private func exportRowLabel(count: Int) -> some View {
        HStack {
            Text("export all notes")
                .font(NFont.body(15))
                .foregroundStyle(NSColorToken.textPrimary)
            Spacer()
            Text("\(count)")
                .font(NFont.mono(11))
                .foregroundStyle(NSColorToken.textGhost)
            Text("↓")
                .font(NFont.mono(13))
                .foregroundStyle(NSColorToken.Phos.cyan)
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .padding(.horizontal, NSpace.md)
        .background(NSColorToken.inkRaised)
        .overlay(Rectangle().stroke(NSColorToken.textGhost.opacity(0.45), lineWidth: 0.5))
    }

    #if os(macOS)
    private func exportAll(_ atoms: [AtomSnapshot], asJSON: Bool) {
        let stem = AtomExport.vaultFileStem()
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        if asJSON {
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "\(stem).json"
        } else {
            panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
            panel.nameFieldStringValue = "\(stem).md"
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let data = asJSON ? AtomExport.json(atoms) : Data(AtomExport.markdown(atoms).utf8)
        do {
            try data.write(to: url, options: .atomic)
            NousLogger.info("export", "vault exported", [
                "count": atoms.count,
                "format": asJSON ? "json" : "markdown"
            ])
        } catch {
            NousLogger.error("export", "vault export failed", [
                "error": error.localizedDescription
            ])
        }
    }
    #endif

    private func cancel() {
        Haptics.shared.softTick()
        withAnimation(.easeOut(duration: 0.18)) { confirming = false }
    }

    private func confirmSignOut() {
        Haptics.shared.heavyThud()
        signingOut = true
        Task { @MainActor in
            await auth.signOut()
            // Keep local atoms — they remain in SwiftData under the prior userID.
            // Next sign-in will migrate them again to the new user. (If we wanted
            // strict session-isolation we'd wipe here; per design brief we don't.)
            signingOut = false
            onDismiss()
        }
    }
}

struct SyncDiagnosticPanel: View {
    @State private var lastAt: Date?
    @State private var lastCount: Int = 0
    @State private var lastError: String?
    @State private var lastUser: String?
    @State private var resyncing = false

    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: NSpace.xs) {
            HStack {
                Text("// sync")
                    .font(NFont.mono(10))
                    .tracking(1.4)
                    .textCase(.uppercase)
                    .foregroundStyle(NSColorToken.textTertiary)
                Spacer()
                Button {
                    Haptics.shared.softTick()
                    resyncing = true
                    NotificationCenter.default.post(name: .nousForceResync, object: nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                        resyncing = false
                        refresh()
                    }
                } label: {
                    HStack(spacing: 4) {
                        if resyncing {
                            ProgressView().controlSize(.mini).tint(NSColorToken.Phos.cyan)
                        }
                        Text(resyncing ? "syncing…" : "force resync")
                            .font(NFont.mono(10))
                            .tracking(1.2)
                            .textCase(.uppercase)
                            .foregroundStyle(NSColorToken.Phos.cyan)
                    }
                }
                .buttonStyle(.plain)
                .disabled(resyncing)
            }
            row(label: "user", value: lastUser?.lowercased() ?? "—")
            row(label: "last pull", value: lastAt.map(relative) ?? "never")
            row(label: "events pulled", value: "\(lastCount)")
            if let err = lastError {
                row(label: "error", value: err, color: NSColorToken.Phos.orange)
            }
        }
        .padding(NSpace.sm)
        .background(NSColorToken.inkRaised)
        .overlay(Rectangle().stroke(NSColorToken.textGhost.opacity(0.30), lineWidth: 0.5))
        .onAppear { refresh() }
        .onReceive(timer) { _ in refresh() }
    }

    private func row(label: String, value: String, color: Color = NSColorToken.textSecondary) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(NFont.mono(10))
                .tracking(1.0)
                .textCase(.uppercase)
                .foregroundStyle(NSColorToken.textGhost)
                .frame(width: 96, alignment: .leading)
            Text(value)
                .font(NFont.mono(10))
                .foregroundStyle(color)
                .lineLimit(2)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    private func refresh() {
        let d = UserDefaults.standard
        lastAt    = d.object(forKey: SyncDaemon.lastPullAtKey) as? Date
        lastCount = d.integer(forKey: SyncDaemon.lastPullCountKey)
        lastError = d.string(forKey: SyncDaemon.lastPullErrorKey)
        lastUser  = d.string(forKey: SyncDaemon.lastPullUserKey)
    }

    private func relative(_ d: Date) -> String {
        let s = max(0, Int(Date().timeIntervalSince(d)))
        if s < 60 { return "\(s)s ago" }
        if s < 3600 { return "\(s / 60)m ago" }
        if s < 86400 { return "\(s / 3600)h ago" }
        return "\(s / 86400)d ago"
    }
}

extension Notification.Name {
    /// Posted by the Account sheet when the user taps "compose". RootView
    /// listens and presents `ComposeSheet`. Decoupled so we don't need to
    /// thread closures through the chip.
    static let nousOpenCompose  = Notification.Name("nous.openCompose")
    /// Force-resync (resets sync cursor + pulls from last 30 days).
    static let nousForceResync  = Notification.Name("nous.forceResync")
}

private struct ChipPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.93 : 1.0)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
    }
}
