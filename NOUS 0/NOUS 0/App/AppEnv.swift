import Foundation

nonisolated enum AppEnv {
    static let supabaseURL = URL(string: "https://ssibcqwsaycnlzlxzked.supabase.co")!
    static let supabaseAnonKey: String = {
        let v = string(for: "NOUS_SUPABASE_ANON_KEY")
        return v.isEmpty ? Secrets.supabaseAnonKey : v
    }()

    static let geminiAPIKey: String = {
        let v = string(for: "NOUS_GEMINI_API_KEY")
        return v.isEmpty ? Secrets.geminiAPIKey : v
    }()

    static let deepgramAPIKey: String = {
        let v = string(for: "NOUS_DEEPGRAM_API_KEY")
        return v.isEmpty ? Secrets.deepgramAPIKey : v
    }()
    static let geminiEmbedModel  = "gemini-embedding-001"
    // Floating alias (intentional, per product decision): always tracks the
    // latest Flash. Refine is latency-sensitive and stays on Flash — do NOT
    // route it to the heavier synthesis model.
    static let geminiRefineModel = "gemini-flash-latest"
    // Higher-reasoning tier for the synthesis / pushback path (see
    // GeminiClient.synthesizeAnswer). Floating Pro alias, analogous to the Flash
    // alias above.
    // ⚠️ UNVERIFIED at runtime in this project — if "gemini-pro-latest" is not a
    // valid model id for this API key/project, synthesis will fail with HTTP 404.
    // Pin to an explicit version (e.g. "gemini-2.5-pro") once availability is
    // confirmed. Easily reverted to `geminiRefineModel` if it breaks.
    static let geminiSynthesisModel = "gemini-pro-latest"
    static let embedDim = 768

    /// Optional: cloud backend (synthesis + pushback). nil if not configured.
    /// Priority: scheme env → Info.plist build setting → Secrets.swift compile-time value.
    static var nousBackendURL: URL? {
        let s = string(for: "NOUS_BACKEND_URL")
        let resolved = s.isEmpty ? Secrets.nousBackendURL : s
        return resolved.isEmpty ? nil : URL(string: resolved)
    }

    /// Pre-auth fallback. Persisted per-install. Used during app first-launch
    /// before sign-in completes (e.g. atoms captured in offline guest mode if
    /// we ever add it). Migrated to the signed-in user's UUID on first sign-in
    /// via `AtomStore.migrateLocalUserToSignedIn(...)`.
    static var localUserID: UUID {
        let key = "nous.localUserID"
        if let s = UserDefaults.standard.string(forKey: key), let u = UUID(uuidString: s) { return u }
        let u = UUID()
        UserDefaults.standard.set(u.uuidString, forKey: key)
        return u
    }

    /// Current effective user ID for cloud writes. Returns the authenticated
    /// session's UUID if signed in, otherwise the pre-auth local UUID.
    /// Hot-path helper — call from any actor / task.
    @MainActor
    static func currentUserID() async -> UUID {
        AuthClient.shared.session?.userID ?? localUserID
    }

    /// Synchronous variant for view code that already runs on MainActor.
    @MainActor
    static var currentUserIDSync: UUID {
        AuthClient.shared.session?.userID ?? localUserID
    }

    /// API keys (NOUS_*_KEY) must NEVER come from UserDefaults — stale values
    /// silently override xcconfig and Secrets.swift on every rebuild.
    /// Priority: process env → Info.plist build setting → compile-time fallback.
    static func string(for key: String) -> String {
        let candidates: [String?] = [
            ProcessInfo.processInfo.environment[key],
            Bundle.main.object(forInfoDictionaryKey: key) as? String,
        ]
        for candidate in candidates {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }

    /// Call once at app launch. Purges any API key values that were accidentally
    /// persisted to UserDefaults in earlier builds (they would shadow xcconfig).
    static func purgeStaleUserDefaultsKeys() {
        let apiKeys = ["NOUS_GEMINI_API_KEY", "NOUS_DEEPGRAM_API_KEY",
                       "NOUS_SUPABASE_ANON_KEY", "NOUS_BACKEND_URL"]
        apiKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }
}
