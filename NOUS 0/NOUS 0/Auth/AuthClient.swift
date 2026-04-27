import Foundation
import AuthenticationServices
import Observation

/// Manages the Supabase auth session for NOUS.
///
/// Flow (Google OAuth):
///   1. Open `<supabase>/auth/v1/authorize?provider=google&redirect_to=nous://auth-callback`
///      via ASWebAuthenticationSession (system Safari sheet, cookies isolated).
///   2. Supabase → Google → Supabase → callback URL with tokens in URL fragment.
///   3. Parse fragment, fetch /auth/v1/user to confirm + grab profile, persist.
///
/// Refresh:
///   - On every accessToken request, check `needsRefresh(leeway: 5m)` and
///     swap if so. Refresh token rotates each call.
///
/// Storage:
///   - Single Keychain item `nous.auth.session.v1` with JSON-encoded AuthSession.
///   - Cleared on sign-out and on refresh failures (forces re-auth).
@Observable
@MainActor
final class AuthClient: NSObject {

    static let shared = AuthClient()

    // Configuration
    private let supabaseURL: URL = AppEnv.supabaseURL
    private let anonKey: String  = AppEnv.supabaseAnonKey
    private let callbackScheme   = "nous"
    private let callbackURLString = "nous://auth-callback"
    private static let sessionKey = "nous.auth.session.v1"

    // State (Observable)
    private(set) var session: AuthSession?
    private(set) var isSigningIn: Bool = false
    private(set) var lastError: String?

    var isAuthenticated: Bool { session != nil }

    private var webAuthSession: ASWebAuthenticationSession?
    private var refreshTask: Task<AuthSession?, Error>?

    override init() {
        super.init()
        loadFromKeychain()
    }

    // MARK: - Bootstrap

    private func loadFromKeychain() {
        guard let data = Keychain.get(Self.sessionKey),
              let decoded = try? JSONDecoder.iso.decode(AuthSession.self, from: data)
        else { return }
        session = decoded
    }

    private func persist(_ s: AuthSession) {
        session = s
        if let data = try? JSONEncoder.iso.encode(s) {
            Keychain.set(data, for: Self.sessionKey)
        }
    }

    private func wipe() {
        session = nil
        Keychain.delete(Self.sessionKey)
    }

    // MARK: - Sign-in (Google)

    /// Open the system Safari sheet for Google OAuth via Supabase. Resolves
    /// when the user finishes (success → returns AuthSession, cancel → throws).
    func signInWithGoogle() async throws -> AuthSession {
        isSigningIn = true
        lastError = nil
        defer { isSigningIn = false }

        let auth = supabaseURL.appendingPathComponent("auth/v1/authorize")
        var comps = URLComponents(url: auth, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "provider", value: "google"),
            URLQueryItem(name: "redirect_to", value: callbackURLString),
        ]
        guard let authURL = comps.url else {
            throw AuthError.malformedRequest
        }

        let callback: URL = try await withCheckedThrowingContinuation { cont in
            let s = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: callbackScheme
            ) { url, err in
                if let err { cont.resume(throwing: err); return }
                guard let url else { cont.resume(throwing: AuthError.cancelled); return }
                cont.resume(returning: url)
            }
            s.presentationContextProvider = self
            s.prefersEphemeralWebBrowserSession = false // share cookies w/ system Safari
            self.webAuthSession = s
            if !s.start() {
                cont.resume(throwing: AuthError.couldNotStart)
            }
        }

        // Tokens come back in the URL fragment, not the query. Supabase format:
        //   nous://auth-callback#access_token=...&refresh_token=...&expires_in=3600&token_type=bearer
        guard let frag = callback.fragment, !frag.isEmpty else {
            throw AuthError.noTokensInCallback
        }
        let pairs = Self.parseFragment(frag)
        guard let access = pairs["access_token"],
              let refresh = pairs["refresh_token"]
        else {
            // Supabase may also send error_description in the fragment.
            let msg = pairs["error_description"] ?? "no tokens"
            throw AuthError.providerError(msg)
        }
        let expiresIn = TimeInterval(pairs["expires_in"] ?? "3600") ?? 3600
        let expiresAt = Date().addingTimeInterval(expiresIn)

        // Fetch the user profile to learn UUID + email + avatar.
        let user = try await fetchUser(accessToken: access)
        let s = AuthSession(
            accessToken: access,
            refreshToken: refresh,
            expiresAt: expiresAt,
            userID: user.id,
            email: user.email,
            avatarURL: user.avatarURL,
            displayName: user.displayName
        )
        persist(s)
        return s
    }

    // MARK: - Sign-out

    func signOut() async {
        if let s = session {
            // Best-effort logout — invalidates the refresh token server-side.
            var req = URLRequest(url: supabaseURL.appendingPathComponent("auth/v1/logout")
                .appending(queryItems: [URLQueryItem(name: "apikey", value: anonKey)]))
            req.httpMethod = "POST"
            req.setValue(anonKey, forHTTPHeaderField: "apikey")
            req.setValue("Bearer \(s.accessToken)", forHTTPHeaderField: "Authorization")
            _ = try? await URLSession.shared.data(for: req)
        }
        wipe()
    }

    // MARK: - Account deletion (GDPR / App Store 5.1.1)

    /// Permanently delete the current user's account from Supabase and wipe local state.
    /// Supabase GoTrue supports self-deletion at DELETE /auth/v1/user.
    func deleteAccount() async throws {
        guard let s = session else { throw AuthError.notAuthenticated }
        var comps2 = URLComponents(url: supabaseURL.appendingPathComponent("auth/v1/user"),
                                   resolvingAgainstBaseURL: false)!
        comps2.queryItems = [URLQueryItem(name: "apikey", value: anonKey)]
        var req = URLRequest(url: comps2.url!)
        req.httpMethod = "DELETE"
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(s.accessToken)", forHTTPHeaderField: "Authorization")
        let (_, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200 || code == 204 || code == 404 else {
            throw NSError(domain: "Auth.deleteAccount", code: code,
                          userInfo: [NSLocalizedDescriptionKey: "account deletion failed (\(code))"])
        }
        wipe()
    }

    // MARK: - Token retrieval (refresh-aware)

    /// Returns a valid access token, refreshing if needed. Throws if no session
    /// OR refresh fails (caller should treat as forced sign-out).
    func validAccessToken() async throws -> String {
        guard let s = session else { throw AuthError.notAuthenticated }
        if !s.needsRefresh() { return s.accessToken }
        // Coalesce concurrent refresh callers onto one in-flight task.
        if let t = refreshTask {
            if let refreshed = try await t.value { return refreshed.accessToken }
            throw AuthError.notAuthenticated
        }
        let task = Task<AuthSession?, Error> { [weak self] in
            guard let self else { return nil }
            return try await self.refreshSession(using: s.refreshToken)
        }
        refreshTask = task
        defer { refreshTask = nil }
        guard let refreshed = try await task.value else { throw AuthError.notAuthenticated }
        return refreshed.accessToken
    }

    /// Sync helper for hot UI paths that just need to know whether to gate a
    /// network call. Not a substitute for `validAccessToken()` before a request.
    var hasValidSession: Bool {
        guard let s = session else { return false }
        return !s.isExpired
    }

    // MARK: - Refresh

    private func refreshSession(using refreshToken: String) async throws -> AuthSession {
        var req = URLRequest(
            url: supabaseURL.appendingPathComponent("auth/v1/token")
                .appending(queryItems: [URLQueryItem(name: "grant_type", value: "refresh_token")])
        )
        req.httpMethod = "POST"
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["refresh_token": refreshToken])

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            // Bad refresh token → force sign-out so user re-auths.
            wipe()
            throw AuthError.refreshFailed
        }
        let decoded = try JSONDecoder().decode(RefreshResponse.self, from: data)
        let expiresAt = Date().addingTimeInterval(TimeInterval(decoded.expires_in))
        let prior = session
        let next = AuthSession(
            accessToken: decoded.access_token,
            refreshToken: decoded.refresh_token,
            expiresAt: expiresAt,
            userID: prior?.userID ?? UUID(),
            email: prior?.email,
            avatarURL: prior?.avatarURL,
            displayName: prior?.displayName
        )
        persist(next)
        return next
    }

    // MARK: - User profile

    private struct UserProfile: Decodable {
        let id: UUID
        let email: String?
        let user_metadata: [String: AnyCodable]?
        private var _avatarURL: URL?
        private var _displayName: String?
        var avatarURL: URL? {
            _avatarURL ?? {
                guard let m = user_metadata, let s = m["avatar_url"]?.stringValue
                else { return nil }
                return URL(string: s)
            }()
        }
        var displayName: String? {
            _displayName ?? user_metadata?["full_name"]?.stringValue ?? user_metadata?["name"]?.stringValue
        }
        init(id: UUID, email: String?, user_metadata: [String: AnyCodable]?,
             _avatarURL: URL? = nil, _displayName: String? = nil) {
            self.id = id; self.email = email; self.user_metadata = user_metadata
            self._avatarURL = _avatarURL; self._displayName = _displayName
        }
    }

    private func fetchUser(accessToken: String) async throws -> UserProfile {
        // Decode claims directly from JWT — avoids needing the anon key for a
        // network call when the token already carries all profile fields.
        if let profile = Self.userProfileFromJWT(accessToken) { return profile }
        throw AuthError.userFetchFailed
    }

    private static func userProfileFromJWT(_ jwt: String) -> UserProfile? {
        let parts = jwt.components(separatedBy: ".")
        guard parts.count == 3 else { return nil }
        var b64 = parts[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sub = json["sub"] as? String,
              let id = UUID(uuidString: sub)
        else { return nil }
        let email = json["email"] as? String
        let meta = json["user_metadata"] as? [String: Any]
        let avatarStr = meta?["avatar_url"] as? String
        let name = meta?["full_name"] as? String ?? meta?["name"] as? String
        return UserProfile(
            id: id, email: email,
            user_metadata: nil,
            _avatarURL: avatarStr.flatMap(URL.init),
            _displayName: name
        )
    }

    // MARK: - Helpers

    /// Parse `key=val&key2=val2` URL fragment with percent-decoding.
    private static func parseFragment(_ frag: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in frag.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2,
               let k = kv[0].removingPercentEncoding,
               let v = kv[1].removingPercentEncoding
            {
                out[k] = v
            }
        }
        return out
    }

    private struct RefreshResponse: Decodable {
        let access_token: String
        let refresh_token: String
        let expires_in: Int
    }
}

// MARK: - Errors

enum AuthError: LocalizedError {
    case malformedRequest
    case couldNotStart
    case cancelled
    case noTokensInCallback
    case providerError(String)
    case userFetchFailed
    case refreshFailed
    case notAuthenticated

    var errorDescription: String? {
        switch self {
        case .malformedRequest:    "could not build auth url"
        case .couldNotStart:       "could not open the sign-in browser"
        case .cancelled:           "sign-in cancelled"
        case .noTokensInCallback:  "auth callback missing tokens"
        case .providerError(let m): "provider error: \(m)"
        case .userFetchFailed:     "could not load profile after sign-in"
        case .refreshFailed:       "session expired — please sign in again"
        case .notAuthenticated:    "not signed in"
        }
    }
}

// MARK: - ASWebAuthenticationPresentationContextProviding

extension AuthClient: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // Find the first connected foreground window. iOS 17+ scene-based.
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first(where: { $0.activationState == .foregroundActive })?
                .windows.first(where: \.isKeyWindow)
                ?? ASPresentationAnchor()
        }
    }
}

// MARK: - JSON helpers
//
// Supabase user_metadata is loosely typed JSON. We need to pull a couple of
// known string fields out of an arbitrary [String: Any]. Tiny boxed type does
// the job without dragging in a JSON library.

struct AnyCodable: Decodable {
    let value: Any
    var stringValue: String? { value as? String }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { value = s }
        else if let i = try? c.decode(Int.self) { value = i }
        else if let d = try? c.decode(Double.self) { value = d }
        else if let b = try? c.decode(Bool.self) { value = b }
        else if let dict = try? c.decode([String: AnyCodable].self) { value = dict }
        else if let arr = try? c.decode([AnyCodable].self) { value = arr }
        else { value = NSNull() }
    }
}

// MARK: - JSONCoder ISO extension (file-scoped to avoid clashing w/ the
// identically-named encoder/decoder declared inside NousBackendClient.swift).

private extension JSONEncoder {
    static let iso: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}

private extension JSONDecoder {
    static let iso: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
