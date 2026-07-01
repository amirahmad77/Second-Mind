#if os(macOS)
import CoreGraphics
import AppKit
import Observation

// ─── MeetingDetector ─────────────────────────────────────────────────────────
//
// Polls CGWindowListCopyWindowInfo every 5 seconds to detect active video-call
// windows: Google Meet in any browser, Zoom, Teams, Webex.
//
// Requires Screen Recording permission — already granted for ScreenCaptureKit.
// CGWindowListCopyWindowInfo returns kCGWindowName == nil without it, so we
// check `hasPermission` and skip polling gracefully if not yet granted.
//
// No AppleScript, no Accessibility API, no extra entitlements.

@MainActor
@Observable
final class MeetingDetector {

    enum Platform: String {
        case googleMeet = "Google Meet"
        case zoom       = "Zoom"
        case teams      = "Microsoft Teams"
        case webex      = "Webex"
    }

    struct DetectedMeeting: Equatable {
        let platform:  Platform
        /// Raw window title (e.g. "Product sync – Google Meet")
        let title:     String
        /// Owning app name (e.g. "Google Chrome")
        let appName:   String

        var platformLabel: String { platform.rawValue }

        /// Cleaned meeting name stripped of the platform suffix
        var meetingName: String {
            var s = title
            for suffix in [" – Google Meet", " - Google Meet",
                           " | Microsoft Teams", " – Zoom",
                           " - Zoom Meeting", " – Cisco Webex"] {
                s = s.replacingOccurrences(of: suffix, with: "")
            }
            return s.trimmingCharacters(in: .whitespaces)
        }
    }

    private(set) var detected: DetectedMeeting?
    private(set) var hasPermission: Bool = true

    private var pollTask: Task<Void, Never>?

    // MARK: – Lifecycle

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.poll()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        detected = nil
    }

    // MARK: – Detection

    private func poll() {
        let result = Self.scan()
        // If we get no window names at all, screen recording likely not granted
        if !result.permissionOK {
            hasPermission = false
            detected = nil
            return
        }
        hasPermission = true
        detected = result.meeting
    }

    private static func scan() -> (meeting: DetectedMeeting?, permissionOK: Bool) {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return (nil, false)
        }

        // If we get windows but all have nil names, permission is denied.
        // Check with a known always-named window (Dock/SystemUIServer).
        let anyName = list.contains { ($0[kCGWindowName as String] as? String) != nil }
        if list.count > 2 && !anyName { return (nil, false) }

        let browsers = ["Google Chrome", "Chromium", "Safari", "Firefox",
                        "Microsoft Edge", "Arc", "Brave Browser", "Opera", "Vivaldi"]

        for window in list {
            guard
                let owner = window[kCGWindowOwnerName as String] as? String,
                let title = window[kCGWindowName as String]       as? String,
                !title.trimmingCharacters(in: .whitespaces).isEmpty
            else { continue }

            let t = title.lowercased()

            // ── Google Meet in browser ────────────────────────────────────────
            if browsers.contains(owner) {
                if t.contains("google meet") || t.contains("meet.google.com")
                    || t.hasSuffix("– google meet") || t.hasSuffix("- google meet") {
                    return (.init(platform: .googleMeet, title: title, appName: owner), true)
                }
            }

            // ── Zoom (native app) ─────────────────────────────────────────────
            if owner == "zoom.us" || owner == "Zoom" {
                if t.contains("zoom meeting") || t.contains("zoom webinar")
                    || (t.contains("zoom") && t.contains("meeting")) {
                    return (.init(platform: .zoom, title: title, appName: "Zoom"), true)
                }
            }
            // Zoom in browser
            if browsers.contains(owner) && t.contains("zoom meeting") {
                return (.init(platform: .zoom, title: title, appName: owner), true)
            }

            // ── Microsoft Teams ────────────────────────────────────────────────
            if owner.contains("Teams") || owner.contains("teams") {
                if t.contains("meeting") || t.contains(" | microsoft teams") {
                    return (.init(platform: .teams, title: title, appName: "Microsoft Teams"), true)
                }
            }
            if browsers.contains(owner) && t.contains("microsoft teams") && t.contains("meeting") {
                return (.init(platform: .teams, title: title, appName: owner), true)
            }

            // ── Webex ──────────────────────────────────────────────────────────
            if owner.lowercased().contains("webex") || owner.lowercased().contains("cisco") {
                if t.contains("webex") || t.contains("meeting") {
                    return (.init(platform: .webex, title: title, appName: owner), true)
                }
            }
        }

        return (nil, true)
    }
}

#endif
