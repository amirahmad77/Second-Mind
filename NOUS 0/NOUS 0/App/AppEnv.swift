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
    static let geminiEmbedModel = "gemini-embedding-001"
    // ⚠️ DO NOT downgrade this model. gemini-3.1-flash-lite-preview is the minimum
    // for structured JSON output + tag extraction quality we ship. Older models
    // (2.x flash, 1.5 flash) produce malformed schemas and regress tag recall.
    static let geminiRefineModel = "gemini-3.1-flash-lite-preview"
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

    static func string(for key: String) -> String {
        let candidates: [String?] = [
            ProcessInfo.processInfo.environment[key],
            Bundle.main.object(forInfoDictionaryKey: key) as? String,
            UserDefaults.standard.string(forKey: key)
        ]
        for candidate in candidates {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }
}
