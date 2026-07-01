#if os(macOS)
import EventKit
import Observation

// ─── CalendarService ──────────────────────────────────────────────────────────
//
// Reads the user's calendar to surface who is in a current or upcoming meeting.
// Used by MeetingSetupSheet to pre-fill the attendees field so Gemini Live can
// map detected voices to real names automatically — no manual typing required.
//
// Detection window:
//   • Events that started up to 15 min ago (user may have started recording late)
//   • Events starting within the next 5 min (user is about to join)
//   Active events (in progress) are preferred; earliest upcoming is the fallback.
//
// Privacy:
//   • Only reads event title + attendee names/emails. No event body, no reminders.
//   • Self (current signed-in email) is excluded from the attendees list —
//     the user is always "You:" in the transcript.
//   • Declined participants are excluded.
//   • All-day events (not real meetings) are skipped.

@MainActor
@Observable
final class CalendarService {
    enum AuthState { case unknown, denied, authorized }

    private(set) var authState: AuthState = .unknown
    private(set) var currentMeeting: MeetingContext?

    private let ekStore = EKEventStore()

    // MARK: – Public API

    struct MeetingContext: Equatable {
        let title:     String
        /// Attendee display names, already filtered (no self, no declined).
        let attendees: [String]
        let startDate: Date
        let endDate:   Date

        var isInProgress: Bool { startDate <= Date() && endDate >= Date() }
        var minutesUntilStart: Int {
            max(0, Int(startDate.timeIntervalSinceNow / 60))
        }

        var attendeesString: String { attendees.joined(separator: ", ") }
    }

    /// Request calendar access and immediately probe for a current/upcoming meeting.
    func activate() async {
        await requestAccess()
        if authState == .authorized {
            currentMeeting = findCurrentMeeting()
        }
    }

    /// Re-probe for current meeting (call when setup sheet opens to get fresh data).
    func refresh() {
        guard authState == .authorized else { return }
        currentMeeting = findCurrentMeeting()
    }

    // MARK: – Access

    private func requestAccess() async {
        let granted: Bool
        if #available(macOS 14.0, *) {
            granted = (try? await ekStore.requestFullAccessToEvents()) ?? false
        } else {
            granted = await withCheckedContinuation { cont in
                ekStore.requestAccess(to: .event) { ok, _ in
                    cont.resume(returning: ok)
                }
            }
        }
        authState = granted ? .authorized : .denied
        NousLogger.info("cal", "calendar access", ["granted": granted ? "yes" : "no"])
    }

    // MARK: – Detection

    private func findCurrentMeeting() -> MeetingContext? {
        let now     = Date()
        // 15 min grace window before start + 5 min look-ahead for upcoming
        let start   = now.addingTimeInterval(-15 * 60)
        let end     = now.addingTimeInterval(5  * 60)

        let predicate = ekStore.predicateForEvents(withStart: start, end: end, calendars: nil)
        let candidates = ekStore.events(matching: predicate)
            .filter { !$0.isAllDay && ($0.endDate ?? now) > now }
            .sorted { $0.startDate < $1.startDate }

        // Prefer in-progress events; otherwise pick the nearest upcoming
        let event = candidates.first { $0.startDate <= now } ?? candidates.first
        guard let event else { return nil }

        let attendees = extractAttendees(from: event)
        return MeetingContext(
            title:     event.title ?? "Meeting",
            attendees: attendees,
            startDate: event.startDate,
            endDate:   event.endDate ?? now.addingTimeInterval(3600)
        )
    }

    // MARK: – Attendee extraction

    private func extractAttendees(from event: EKEvent) -> [String] {
        guard let participants = event.attendees, !participants.isEmpty else { return [] }

        // Collect self-identifiers to exclude
        let selfEmail = AuthClient.shared.session?.email?.lowercased() ?? ""

        return participants.compactMap { p -> String? in
            // Skip declined and optional-declined
            guard p.participantStatus != .declined else { return nil }
            // Skip self by email match
            let email = p.url.absoluteString
                .replacingOccurrences(of: "mailto:", with: "")
                .lowercased()
                .trimmingCharacters(in: .whitespaces)
            if !selfEmail.isEmpty, email.hasPrefix(selfEmail) { return nil }
            // Skip organiser if it's the current user (EKParticipantRole.organizer)
            // — they show up in attendees but are already "You:" in the transcript
            if p.isCurrentUser { return nil }

            // Prefer display name; fall back to email local part
            let name = (p.name ?? "")
                .trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { return name }
            let localPart = String(email.split(separator: "@").first ?? "")
            // Humanise "first.last" → "First Last"
            return localPart
                .split(separator: ".")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        }
    }
}

#endif
