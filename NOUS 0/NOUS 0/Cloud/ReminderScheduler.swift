import Foundation
import UserNotifications

/// Local notification scheduler for task due dates (R3).
///
/// Cross-platform: `UserNotifications` ships on iOS, macOS (10.14+), watchOS, tvOS.
/// One pending notification per atom — keyed by a deterministic identifier so a
/// re-scheduled due date replaces the previous one rather than stacking.
///
/// All work is funnelled through `UNUserNotificationCenter.current()`, which is
/// thread-safe; the type itself is `@MainActor` so it can be touched freely from
/// `AtomStore` (also `@MainActor`) without isolation hops. The center's async
/// calls run off-actor and are awaited.
@MainActor
enum ReminderScheduler {
    /// userInfo key carrying the atom id so a notification tap can deep-link.
    static let atomIDUserInfoKey = "nous.reminder.atomID"

    /// Notification body is truncated to keep banners readable.
    private static let maxBodyLength = 120

    private static func identifier(for atomID: UUID) -> String {
        "nous.reminder.\(atomID.uuidString)"
    }

    /// Lazily request alert+sound authorization. Safe to call repeatedly — the
    /// system only prompts once; subsequent calls resolve against the stored grant.
    /// Returns silently on failure (logged) so callers never need to handle errors.
    static func requestAuthorizationIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        // Only prompt when undetermined. Denied/authorized are terminal — re-asking
        // does nothing useful and a denied user can re-enable in System Settings.
        guard settings.authorizationStatus == .notDetermined else { return }
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            NousLogger.info("reminder", "authorization request resolved", ["granted": "\(granted)"])
        } catch {
            NousLogger.warning("reminder", "authorization request failed",
                               ["error": error.localizedDescription])
        }
    }

    /// Schedule (or replace) a local reminder firing at `dueAt`.
    /// No-ops when `dueAt` is in the past — a notification can't fire backwards.
    /// `title` is the atom's one-liner / display content; it is truncated for the body.
    static func schedule(atomID: UUID, title: String, dueAt: Date) async {
        guard dueAt > Date() else {
            NousLogger.debug("reminder", "skip schedule — due date in past",
                             ["atomID": atomID.uuidString])
            // Defensive: clear any stale pending request for this atom.
            cancel(atomID: atomID)
            return
        }

        // Ensure we have permission before staging the request.
        await requestAuthorizationIfNeeded()

        let content = UNMutableNotificationContent()
        content.title = "Reminder"
        content.body = Self.truncatedBody(title)
        content.sound = .default
        content.userInfo = [Self.atomIDUserInfoKey: atomID.uuidString]

        // Calendar trigger to the minute — UNCalendarNotificationTrigger fires at a
        // wall-clock point, which survives suspension better than a time-interval delta.
        let comps = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute], from: dueAt
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let request = UNNotificationRequest(
            identifier: Self.identifier(for: atomID),
            content: content,
            trigger: trigger
        )

        do {
            let center = UNUserNotificationCenter.current()
            // Replacing same-identifier request is implicit, but remove first to be
            // explicit about single-pending-per-atom semantics.
            center.removePendingNotificationRequests(withIdentifiers: [Self.identifier(for: atomID)])
            try await center.add(request)
            NousLogger.info("reminder", "scheduled",
                            ["atomID": atomID.uuidString, "dueAt": "\(dueAt)"])
        } catch {
            NousLogger.warning("reminder", "schedule failed",
                               ["atomID": atomID.uuidString, "error": error.localizedDescription])
        }
    }

    /// Cancel the pending (and any already-delivered) reminder for an atom.
    static func cancel(atomID: UUID) {
        let center = UNUserNotificationCenter.current()
        let id = Self.identifier(for: atomID)
        center.removePendingNotificationRequests(withIdentifiers: [id])
        center.removeDeliveredNotifications(withIdentifiers: [id])
        NousLogger.debug("reminder", "cancelled", ["atomID": atomID.uuidString])
    }

    private static func truncatedBody(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Task due" }
        if trimmed.count <= maxBodyLength { return trimmed }
        return String(trimmed.prefix(maxBodyLength)) + "…"
    }
}
