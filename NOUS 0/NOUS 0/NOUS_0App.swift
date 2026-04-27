import SwiftUI
import SwiftData
#if os(iOS) || os(visionOS)
import CoreSpotlight
import UserNotifications
#endif

// ─── NOUS App Entry Point ─────────────────────────────────────────────────────
//
// Single @main handles both iOS and macOS.
// Platform-specific scene setup lives in #if os(...) blocks below.
// Shared: model container, auth gate, Secrets seeding.

@main
struct NOUS_0App: App {
    @State private var auth = AuthClient.shared

    #if os(iOS) || os(visionOS)
    @State private var pendingAtomID: UUID?
    #endif

    init() {
        seedDefaults()
        #if os(macOS)
        MacGlobalHotkey.register()
        #else
        UNUserNotificationCenter.current().delegate = ProactiveNotificationDelegate.shared
        #endif
    }

    var body: some Scene {
        #if os(macOS)
        macScenes
        #else
        iosScenes
        #endif
    }

    // MARK: – Secrets seeding

    private func seedDefaults() {
        let ud = UserDefaults.standard
        func seed(_ key: String, _ value: String) {
            guard !value.isEmpty,
                  (ud.string(forKey: key) ?? "").isEmpty else { return }
            ud.set(value, forKey: key)
        }
        seed("NOUS_GEMINI_API_KEY",    Secrets.geminiAPIKey)
        seed("NOUS_SUPABASE_ANON_KEY", Secrets.supabaseAnonKey)
        seed("NOUS_BACKEND_URL",       Secrets.nousBackendURL)
        seed("NOUS_AXIOM_TOKEN",       Secrets.axiomToken)
        seed("NOUS_AXIOM_DATASET",     Secrets.axiomDataset)
        seed("NOUS_AXIOM_URL",         Secrets.axiomURL)
    }

    // MARK: – macOS scenes

    #if os(macOS)
    @SceneBuilder
    private var macScenes: some Scene {
        // Main three-column window
        WindowGroup("NOUS", id: "main") {
            if auth.isAuthenticated {
                MacRootView()
            } else {
                SignInView(auth: auth)
            }
        }
        .modelContainer(for: [NoteEventRecord.self, EmbeddingRecord.self])
        .defaultSize(width: 1100, height: 720)
        .commands {
            macCommands
        }

        // Menu bar extra — quick capture from anywhere
        MenuBarExtra("NOUS", systemImage: "circle.fill") {
            MacMenuBarContent(auth: auth)
        }
        .menuBarExtraStyle(.window)
    }

    @CommandsBuilder
    private var macCommands: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Capture") {
                NotificationCenter.default.post(name: .nousOpenCapture, object: nil)
            }
            .keyboardShortcut("n", modifiers: .command)
        }
    }
    #endif

    // MARK: – iOS / visionOS scenes

    #if os(iOS) || os(visionOS)
    @SceneBuilder
    private var iosScenes: some Scene {
        WindowGroup {
            ZStack {
                if auth.isAuthenticated {
                    RootView(pendingAtomID: $pendingAtomID)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                } else {
                    SignInView(auth: auth)
                        .transition(.opacity)
                }
            }
            .animation(.timingCurve(0.32, 0.72, 0.0, 1.0, duration: 0.42), value: auth.isAuthenticated)
            .onContinueUserActivity(CSSearchableItemActionType) { activity in
                guard let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
                      let uuid = UUID(uuidString: id) else { return }
                pendingAtomID = uuid
            }
            .onOpenURL { url in
                guard url.scheme == "nous", url.host == "atom" else { return }
                let id = String(url.path.dropFirst())
                if let uuid = UUID(uuidString: id) { pendingAtomID = uuid }
            }
            .onAppear {
                ProactiveNotificationDelegate.shared.onAtomTapped = { id in
                    pendingAtomID = id
                }
            }
        }
        .modelContainer(for: [NoteEventRecord.self, EmbeddingRecord.self])
    }
    #endif
}
