import Foundation

/// Persisted session shape. Stored as JSON in Keychain under one key.
///
/// Refresh token rotates on every refresh — Supabase invalidates the old one
/// after a single use. We always re-write the keychain item after refresh.
struct AuthSession: Codable, Sendable, Equatable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date           // wall clock; we refresh ~5min before
    let userID: UUID
    let email: String?
    let avatarURL: URL?
    let displayName: String?

    var isExpired: Bool { Date() >= expiresAt }

    /// True when the access token is within `leeway` of expiry. Used to
    /// proactively refresh before next request.
    func needsRefresh(leeway: TimeInterval = 300) -> Bool {
        Date().addingTimeInterval(leeway) >= expiresAt
    }
}
