import Foundation
import Observation

/// Periodic epistemic-pushback fetcher.
/// Fires on bootstrap + every refresh; results surface as a small badge near
/// the Orb. Items are dismissible per-session (not persisted to atoms — they're
/// suggestions, not commitments).
@Observable
@MainActor
final class PushbackVM {

    private(set) var items: [NousBackendClient.PushbackItem] = []
    private(set) var isFetching = false
    private(set) var lastFetchAt: Date?
    private(set) var lastError: String?

    /// Per-item snooze map. Value is the timestamp at which the item becomes
    /// visible again. `Date.distantFuture` = dismissed forever. Persisted to
    /// UserDefaults so snoozes survive relaunch.
    private var snoozedUntil: [String: Date] = [:]
    private static let snoozeKey = "nous.pushback.snoozedUntil.v1"

    var visibleItems: [NousBackendClient.PushbackItem] {
        let now = Date()
        return items.filter { (snoozedUntil[$0.id] ?? .distantPast) <= now }
    }
    var hasItems: Bool { !visibleItems.isEmpty }

    private let backend: NousBackendClient
    private let userID: UUID
    private var task: Task<Void, Never>?

    init(backend: NousBackendClient, userID: UUID) {
        self.backend = backend
        self.userID = userID
        loadSnoozes()
    }

    // MARK: - Snooze persistence

    private func loadSnoozes() {
        guard let data = UserDefaults.standard.data(forKey: Self.snoozeKey),
              let decoded = try? JSONDecoder().decode([String: Date].self, from: data)
        else { return }
        // Drop already-expired entries on load so the dictionary doesn't grow unbounded.
        let now = Date()
        snoozedUntil = decoded.filter { $0.value > now }
    }

    private func saveSnoozes() {
        // Same prune-on-write so storage stays bounded.
        let now = Date()
        let live = snoozedUntil.filter { $0.value > now }
        snoozedUntil = live
        if let data = try? JSONEncoder().encode(live) {
            UserDefaults.standard.set(data, forKey: Self.snoozeKey)
        }
    }

    /// Fire-and-forget. Replaces in-flight fetch.
    func refresh(sinceDays: Int = 14, maxAtoms: Int = 30) {
        guard backend.isConfiguredSync else { return }
        task?.cancel()
        isFetching = true
        lastError = nil
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let fetched = try await self.backend.pushbackItems(
                    userID: self.userID,
                    sinceDays: sinceDays,
                    maxAtoms: maxAtoms
                )
                if Task.isCancelled { return }
                self.items = fetched
                self.lastFetchAt = .now
            } catch {
                if !Task.isCancelled { self.lastError = error.localizedDescription }
            }
            self.isFetching = false
        }
    }

    /// Tap-dismiss = soft snooze: out of sight for 24h, back if still relevant.
    /// Default behavior because most pushback prompts deserve another look.
    func snooze(_ item: NousBackendClient.PushbackItem, hours: Double = 24) {
        snoozedUntil[item.id] = Date().addingTimeInterval(hours * 3600)
        saveSnoozes()
    }

    /// Long-press dismiss = forever. User has decided this prompt is irrelevant
    /// to their work. Persisted permanently (well: until UserDefaults reset).
    func dismissForever(_ item: NousBackendClient.PushbackItem) {
        snoozedUntil[item.id] = .distantFuture
        saveSnoozes()
    }

    /// Legacy dismiss alias — kept so any old call sites don't break. Treat
    /// as a soft snooze (24h) per the new vocabulary.
    func dismiss(_ item: NousBackendClient.PushbackItem) {
        snooze(item)
    }

    func clear() {
        items = []
        snoozedUntil = [:]
        UserDefaults.standard.removeObject(forKey: Self.snoozeKey)
    }
}

// MARK: - Backend isConfigured sync helper
// Avoids actor hop for hot-path UI checks.

extension NousBackendClient {
    /// Synchronous shadow of `isConfigured`. Read-only check against AppEnv.
    nonisolated var isConfiguredSync: Bool { AppEnv.nousBackendURL != nil }
}
