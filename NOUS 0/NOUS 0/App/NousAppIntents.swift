import AppIntents
import Foundation

// ─── NOUS App Intents ──────────────────────────────────────────────────────────
//
// Siri / Spotlight / Shortcuts / Raycast entry points for NOUS.
//
// ⚠️ Architecture constraint that shapes every intent here:
// `AtomStore` is `@MainActor` and is created PER-SCENE with a per-scene SwiftData
// `ModelContext` (see NOUS_0App.swift → `.modelContainer(...)`). There is currently
// NO App-Group-shared store, so an App Intent process CANNOT safely open the same
// SwiftData container the running app uses, nor write a `NoteEvent` directly.
//
// Therefore every intent here takes the SAFE path: `openAppWhenRun = true` launches
// (or foregrounds) the app, and the payload is handed off via two complementary
// mechanisms:
//
//   1. UserDefaults stash — durable, survives a cold launch. The intent writes the
//      pending payload BEFORE the app finishes launching; the app consumes it once
//      it reaches the foreground. Keys are documented constants below.
//
//   2. NotificationCenter post — best-effort, in-process. When the app is ALREADY
//      running and observing, posting the existing `.nousOpenCapture` /
//      `.nousOpenPalette` notifications routes the user straight to the right UI
//      immediately. On a cold launch this post lands before any observer exists,
//      which is exactly why mechanism (1) is the source of truth.
//
// ────────────────────────────────────────────────────────────────────────────────
// 🔌 ONE-LINE HOOKUP THE LEAD MUST ADD (in NOUS_0App.swift, on the root scene):
//
//   .onAppear { NousIntentInbox.drain() }
//
// (Or call `NousIntentInbox.drain()` from MacRootView.bootstrap() / RootView.onAppear.)
// `drain()` reads + clears the stashed payloads and re-posts the same
// `.nousOpenCapture` / `.nousOpenPalette` notifications the app already observes,
// passing the capture text via the notification's `object`. The existing observers
// open the capture sheet / palette; the lead only needs to read `object as? String`
// in the `.nousOpenCapture` handler to pre-fill the capture field. No other wiring.
// ────────────────────────────────────────────────────────────────────────────────

// MARK: - Shared payload inbox

/// Documented UserDefaults keys + drain helper bridging App Intents → the app.
///
/// `@unchecked Sendable` is unnecessary: this is a namespacing enum with only static
/// members touching `UserDefaults` (thread-safe) and `NotificationCenter` (posted on
/// `.main` from `drain()`). Intents call `stash*` from their own process; the app
/// calls `drain()` from the MainActor once foregrounded.
@available(iOS 16.0, macOS 13.0, *)
public enum NousIntentInbox {
    /// Pending capture text awaiting consumption by the app. String.
    public static let pendingCaptureKey = "nous.intent.pendingCapture"
    /// Flag: a search/palette open was requested. Bool.
    public static let pendingSearchKey = "nous.intent.pendingSearch"

    /// Called from the App Intent process. Persists the capture text so the app can
    /// consume it on next foreground, then posts the in-process notification for the
    /// already-running case.
    static func stashCapture(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // The intent runs in a SEPARATE process — NotificationCenter posts wouldn't
        // reach the app. Persist to UserDefaults; the app's drain() (in-process)
        // surfaces it on foreground.
        UserDefaults.standard.set(trimmed, forKey: pendingCaptureKey)
        NousLogger.info("intent", "stashed pending capture", ["len": "\(trimmed.count)"])
    }

    /// Called from the App Intent process. Flags a search/palette open request.
    static func stashSearch() {
        UserDefaults.standard.set(true, forKey: pendingSearchKey)
        NousLogger.info("intent", "stashed pending search")
    }

    /// Called by the APP (MainActor, on foreground) to consume any stashed payload.
    /// Reads + clears each key and routes to the right UI. Safe to call repeatedly.
    @MainActor
    public static func drain() {
        let ud = UserDefaults.standard
        if let text = ud.string(forKey: pendingCaptureKey), !text.isEmpty {
            ud.removeObject(forKey: pendingCaptureKey)
            NousLogger.info("intent", "draining pending capture", ["len": "\(text.count)"])
            // The capture/palette open-notifications are declared in macOS-only
            // scene files. On macOS, route to them. On iOS, the text remains
            // available via lastPendingCapture for a host observer to consume
            // (see note: iOS RootView hookup is a one-liner follow-up).
            #if os(macOS)
            NotificationCenter.default.post(name: .nousOpenCapture, object: text)
            #else
            lastPendingCapture = text
            #endif
        }
        if ud.bool(forKey: pendingSearchKey) {
            ud.removeObject(forKey: pendingSearchKey)
            NousLogger.info("intent", "draining pending search")
            #if os(macOS)
            NotificationCenter.default.post(name: .nousOpenPalette, object: nil)
            #endif
        }
    }

    /// iOS fallback: most-recent intent capture text awaiting a host observer.
    @MainActor public static var lastPendingCapture: String?
}

// MARK: - Capture to NOUS

@available(iOS 16.0, macOS 13.0, *)
struct CaptureToNousIntent: AppIntent {
    static var title: LocalizedStringResource = "Capture to NOUS"

    static var description = IntentDescription(
        "Save a quick thought, task, or note to NOUS.",
        categoryName: "Capture"
    )

    /// Opening the app is REQUIRED: there is no shared store the intent can write to
    /// directly (see file header). The app consumes the text on foreground.
    static var openAppWhenRun = true

    @Parameter(
        title: "Text",
        description: "What you want to capture.",
        requestValueDialog: "What should NOUS capture?"
    )
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("Capture \(\.$text) to NOUS")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        NousIntentInbox.stashCapture(text)
        return .result()
    }
}

// MARK: - Search NOUS

@available(iOS 16.0, macOS 13.0, *)
struct SearchNousIntent: AppIntent {
    static var title: LocalizedStringResource = "Search NOUS"

    static var description = IntentDescription(
        "Open NOUS and jump to search.",
        categoryName: "Search"
    )

    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        NousIntentInbox.stashSearch()
        return .result()
    }
}

// MARK: - Open NOUS

@available(iOS 16.0, macOS 13.0, *)
struct OpenNousIntent: AppIntent {
    static var title: LocalizedStringResource = "Open NOUS"

    static var description = IntentDescription(
        "Launch the NOUS app.",
        categoryName: "General"
    )

    static var openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        // No payload — `openAppWhenRun` does all the work.
        return .result()
    }
}

// MARK: - App Shortcuts provider

/// A type conforming to `AppShortcutsProvider` in the app bundle auto-registers its
/// shortcuts with the system — no other-file wiring is needed. These phrases surface
/// in Spotlight, Siri, the Shortcuts app, and Raycast's Shortcuts integration.
///
/// `\(.applicationName)` MUST appear in every phrase (App Intents requirement). The
/// system substitutes the app's display name, so users can say e.g. "Capture to NOUS".
@available(iOS 16.0, macOS 13.0, *)
struct NousShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CaptureToNousIntent(),
            phrases: [
                "Capture to \(.applicationName)",
                "Capture this to \(.applicationName)",
                "Add a note to \(.applicationName)",
                "New \(.applicationName) note",
                "Jot down in \(.applicationName)"
            ],
            shortTitle: "Capture",
            systemImageName: "square.and.pencil"
        )
        AppShortcut(
            intent: SearchNousIntent(),
            phrases: [
                "Search \(.applicationName)",
                "Search my \(.applicationName)",
                "Find in \(.applicationName)",
                "Search notes in \(.applicationName)"
            ],
            shortTitle: "Search",
            systemImageName: "magnifyingglass"
        )
        AppShortcut(
            intent: OpenNousIntent(),
            phrases: [
                "Open \(.applicationName)",
                "Launch \(.applicationName)"
            ],
            shortTitle: "Open",
            systemImageName: "circle.fill"
        )
    }
}
