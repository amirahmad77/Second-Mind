import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

/// Publishes a lightweight snapshot of the vault to the App Group so the widget
/// extension can render without folding the event ledger itself. The app writes;
/// the widget reads the same `UserDefaults(suiteName:)` + key.
///
/// Decoupling via a small snapshot (rather than letting the widget open the
/// SwiftData store and fold events) keeps the widget cheap and avoids running
/// the reducer in a memory-constrained extension.
enum WidgetBridge {
    /// Must match the key the widget reads. (The widget target duplicates this
    /// tiny contract since it can't import the app module.)
    static let snapshotKey = "nous.widget.snapshot"

    struct Snapshot: Codable {
        struct Item: Codable {
            let id: String
            let line: String
            let type: String
            let due: Date?
        }
        let recent: [Item]
        let openTaskCount: Int
        let updatedAt: Date
    }

    private static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: NousStore.appGroupID)
    }

    /// Write the current snapshot and ask WidgetKit to refresh. Cheap; safe to
    /// call on every store change (the system throttles actual widget reloads).
    static func publish(recent: [Snapshot.Item], openTaskCount: Int) {
        guard let defaults = sharedDefaults else { return }
        let snap = Snapshot(recent: recent, openTaskCount: openTaskCount, updatedAt: Date())
        guard let data = try? JSONEncoder().encode(snap) else { return }
        defaults.set(data, forKey: snapshotKey)
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    /// Read the latest snapshot (used by the widget; also handy for tests).
    static func loadSnapshot() -> Snapshot? {
        guard let defaults = sharedDefaults,
              let data = defaults.data(forKey: snapshotKey) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }
}
