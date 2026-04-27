import Foundation
import UserNotifications

/// Proactive resurfacing — once-daily local notification reminding the user of
/// an old atom they haven't returned to in a while. Picks anchor atoms (those
/// with inbound links — i.e. ideas the user has connected to from other notes)
/// since those carry more signal than orphan captures.
///
/// Storage:
///   `nous.proactive.enabled` — Bool toggle
///   `nous.proactive.hour`    — Int 0..23 fire hour (default 8)
///
/// Lifecycle:
///   - Enable toggle → request authorization → schedule next 7 days
///   - On every app launch (when enabled), reschedule to keep the queue topped up
///   - Notification tap → app receives userInfo["atomID"] → deep-link path
@MainActor
final class ProactiveSurface {
    static let shared = ProactiveSurface()

    static let enabledKey = "nous.proactive.enabled"
    static let hourKey    = "nous.proactive.hour"
    private static let identifierPrefix = "nous.proactive."

    private static let staleAfterDays  = 42      // 6 weeks
    private static let scheduleHorizon = 7       // days to schedule ahead

    private init() {}

    /// RootView calls this on bootstrap so Settings toggles can reschedule
    /// without piping the store through view layers.
    private weak var attachedStore: AtomStore?
    func attach(store: AtomStore) { self.attachedStore = store }
    private func resolveStore(_ provided: AtomStore?) -> AtomStore? {
        provided ?? attachedStore
    }

    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? false
    }

    var fireHour: Int {
        let h = UserDefaults.standard.object(forKey: Self.hourKey) as? Int ?? 8
        return max(0, min(23, h))
    }

    func setEnabled(_ on: Bool, store: AtomStore?) async {
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        if on {
            let ok = await requestAuthorization()
            guard ok else {
                UserDefaults.standard.set(false, forKey: Self.enabledKey)
                return
            }
            await reschedule(store: store)
        } else {
            cancelAll()
        }
    }

    func setHour(_ h: Int, store: AtomStore?) async {
        UserDefaults.standard.set(max(0, min(23, h)), forKey: Self.hourKey)
        guard isEnabled else { return }
        await reschedule(store: store)
    }

    /// Idempotent. Cancels existing nous.proactive.* notifications and
    /// schedules fresh ones for the next `scheduleHorizon` days.
    func reschedule(store: AtomStore?) async {
        guard isEnabled, let store = resolveStore(store) else { return }
        cancelAll()
        let candidates = pickCandidates(store: store, count: Self.scheduleHorizon)
        guard !candidates.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        let cal = Calendar.current
        let now = Date()
        for (offset, atom) in candidates.enumerated() {
            let fireDate = cal.date(bySettingHour: fireHour, minute: 0, second: 0,
                                    of: cal.date(byAdding: .day, value: offset + 1, to: now) ?? now)
                ?? now.addingTimeInterval(Double(offset + 1) * 86_400)
            let content = UNMutableNotificationContent()
            content.title = "from your past"
            content.body  = previewLine(for: atom)
            content.userInfo = ["atomID": atom.id.uuidString]
            content.sound = .default
            let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            let req = UNNotificationRequest(
                identifier: "\(Self.identifierPrefix)\(atom.id.uuidString)",
                content: content,
                trigger: trigger
            )
            try? await center.add(req)
        }
    }

    func cancelAll() {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { reqs in
            let ids = reqs.map(\.identifier).filter { $0.hasPrefix(Self.identifierPrefix) }
            center.removePendingNotificationRequests(withIdentifiers: ids)
        }
    }

    // MARK: - Selection

    private func pickCandidates(store: AtomStore, count: Int) -> [AtomSnapshot] {
        let now = Date()
        let staleSeconds = TimeInterval(Self.staleAfterDays) * 86_400
        let pool = store.ordered.filter { a in
            guard !a.isDeleted else { return false }
            return now.timeIntervalSince(a.updatedAt) >= staleSeconds
        }
        guard !pool.isEmpty else { return [] }

        // Score: inbound count (anchor signal) + age in weeks (older = better)
        let scored: [(AtomSnapshot, Double)] = pool.map { a in
            let inbound = Double(store.inboundCount(of: a.id))
            let weeks = now.timeIntervalSince(a.updatedAt) / (86_400 * 7)
            let score = (1.0 + inbound) * log2(2 + weeks)
            return (a, score)
        }

        // Weighted random sampling without replacement (Efraimidis-Spirakis).
        var bag = scored.map { (atom: $0.0, key: pow(Double.random(in: 0.001...1.0), 1.0 / max($0.1, 0.001))) }
        bag.sort { $0.key > $1.key }
        return bag.prefix(count).map { $0.atom }
    }

    private func previewLine(for atom: AtomSnapshot) -> String {
        let raw = atom.refinedContent ?? atom.rawContent
        let firstLine = raw.split(whereSeparator: \.isNewline).first.map(String.init) ?? raw
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        if trimmed.count > 90 {
            return String(trimmed.prefix(87)) + "…"
        }
        return trimmed
    }

    // MARK: - Authorization

    private func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }
}

// MARK: - Notification delegate

/// App-level delegate so taps deep-link to the atom even when the app was
/// terminated. Set `pendingAtomID` (a callback) on launch from NOUS_0App.
final class ProactiveNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ProactiveNotificationDelegate()

    /// Set by the App scene; receives the UUID extracted from a notification tap.
    var onAtomTapped: ((UUID) -> Void)?

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                @escaping (UNNotificationPresentationOptions) -> Void) {
        // Show banner + sound even while app is foregrounded.
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        defer { completionHandler() }
        guard let s = response.notification.request.content.userInfo["atomID"] as? String,
              let id = UUID(uuidString: s) else { return }
        onAtomTapped?(id)
    }
}
