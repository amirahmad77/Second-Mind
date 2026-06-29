import SwiftUI
import SwiftData
import CoreText
#if os(macOS)
import CoreGraphics
#endif
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
        // Register bundled fonts before any SwiftUI view body runs so
        // Font.custom("DepartureMono-Regular", ...) resolves on first use.
        // On iOS this is redundant (UIAppFonts handles it) but harmless.
        // On macOS (sandbox) ATSApplicationFontsPath doesn't work — CTFontManager
        // is the only reliable registration path.
        NFont.registerBundledFonts()

        // Evict any API keys that were cached in UserDefaults by earlier builds.
        // AppEnv.string(for:) no longer reads UserDefaults, but stale values
        // sitting there can cause confusion — purge them once on every launch.
        AppEnv.purgeStaleUserDefaultsKeys()
        seedDefaults()
        #if os(macOS)
        // On macOS 26 (Tahoe), apps that have a MenuBarExtra scene can be
        // assigned .accessory activation policy by the OS. Accessory apps render
        // windows but those windows don't receive mouse events without explicit
        // activation — they look interactive but every click is silently dropped.
        // Forcing .regular here, before SwiftUI builds its scene graph, prevents
        // the OS from downgrading the policy and guarantees the main window is
        // fully interactive from first click.
        NSApplication.shared.setActivationPolicy(.regular)
        MacGlobalHotkey.register()
        // Request Screen Recording permission early (needed for ScreenCaptureKit
        // system-audio capture during meetings). Shows the system prompt on first
        // launch; subsequent launches are silently granted.
        CGRequestScreenCaptureAccess()
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
        // API keys (NOUS_*_KEY) are NOT seeded here — they come from
        // LocalSecrets.xcconfig → Info.plist → Secrets.swift at build time.
        // Seeding them into UserDefaults caused stale expired keys to survive
        // across rebuilds because the guard below never updates existing values.
        //
        // Only seed non-secret config that legitimately lives in UserDefaults.
        let ud = UserDefaults.standard
        func seed(_ key: String, _ value: String) {
            guard !value.isEmpty,
                  (ud.string(forKey: key) ?? "").isEmpty else { return }
            ud.set(value, forKey: key)
        }
        seed("NOUS_AXIOM_DATASET",     Secrets.axiomDataset)
        seed("NOUS_AXIOM_URL",         Secrets.axiomURL)
    }

    // MARK: – macOS scenes

    #if os(macOS)
    @SceneBuilder
    private var macScenes: some Scene {
        // Main three-column window
        WindowGroup("NOUS", id: "main") {
            Group {
                if auth.isAuthenticated {
                    MacRootView()
                } else {
                    SignInView(auth: auth)
                }
            }
            // Floor below which the three columns (sidebar + list + detail)
            // compress into illegibility. Keeps every pane usable on resize.
            .frame(minWidth: 760, minHeight: 480)
            .onAppear {
                // Drain any pending App Intent (Capture/Search to NOUS) that
                // launched the app, routing it to the capture/palette surfaces.
                NousIntentInbox.drain()
                // Re-assert .regular after SwiftUI scene setup, which can
                // silently downgrade policy back to .accessory on macOS 26.
                NSApplication.shared.setActivationPolicy(.regular)

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    // Diagnostic: print every window's state to Xcode console.
                    // Look for ignoresMouseEvents=true or isKeyWindow=false.
                    for (i, win) in NSApplication.shared.windows.enumerated() {
                        let info = "[\(i)] '\(win.title)' key=\(win.isKeyWindow) " +
                            "main=\(win.isMainWindow) visible=\(win.isVisible) " +
                            "ignoresMouse=\(win.ignoresMouseEvents) " +
                            "level=\(win.level.rawValue) class=\(type(of: win))"
                        print("[NOUS-DIAG] \(info)")
                        NousLogger.info("mac.window", "window state", [
                            "idx": "\(i)", "title": win.title,
                            "isKey": "\(win.isKeyWindow)",
                            "ignoresMouse": "\(win.ignoresMouseEvents)",
                            "level": "\(win.level.rawValue)"
                        ])
                        // Force all windows to accept mouse events.
                        win.ignoresMouseEvents = false
                    }
                    print("[NOUS-DIAG] activationPolicy=\(NSApplication.shared.activationPolicy().rawValue)")
                    // Bring main window forward and make it key.
                    let mainWin = NSApplication.shared.windows
                        .first(where: { $0.isVisible && !$0.isMiniaturized && !($0 is NSPanel) })
                    mainWin?.makeKeyAndOrderFront(nil)
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
            }
        }
        .modelContainer(NousStore.shared)
        .defaultSize(width: 1100, height: 720)
        .windowResizability(.contentMinSize)
        .commands {
            macCommands
        }

        // Menu bar extra — quick capture from anywhere
        MenuBarExtra("NOUS", systemImage: "circle.fill") {
            MacMenuBarContent(auth: auth)
        }
        .menuBarExtraStyle(.window)

        // Settings scene — opens via the standard ⌘, shortcut.
        Settings {
            SettingsView()
        }
    }

    @CommandsBuilder
    private var macCommands: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Capture") {
                NotificationCenter.default.post(name: .nousOpenCapture, object: nil)
            }
            .keyboardShortcut("n", modifiers: .command)

            Button("Command Palette") {
                NotificationCenter.default.post(name: .nousOpenPalette, object: nil)
            }
            .keyboardShortcut("k", modifiers: .command)
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
                // Drain any pending App Intent (Capture/Search to NOUS) that
                // launched the app.
                NousIntentInbox.drain()
                ProactiveNotificationDelegate.shared.onAtomTapped = { id in
                    pendingAtomID = id
                }
            }
        }
        .modelContainer(NousStore.shared)
    }
    #endif
}
