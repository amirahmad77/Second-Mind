import Foundation

nonisolated enum AppEnv {
    static let supabaseURL = URL(string: "https://ssibcqwsaycnlzlxzked.supabase.co")!
    static let supabaseAnonKey = Secrets.supabaseAnonKey

    static let geminiAPIKey = Secrets.geminiAPIKey
    static let geminiEmbedModel = "gemini-embedding-001"
    static let geminiRefineModel = "gemini-2.5-flash"
    static let embedDim = 768

    /// Single-user v1. Persistent per-install user id.
    static var localUserID: UUID {
        let key = "nous.localUserID"
        if let s = UserDefaults.standard.string(forKey: key), let u = UUID(uuidString: s) { return u }
        let u = UUID()
        UserDefaults.standard.set(u.uuidString, forKey: key)
        return u
    }
}
