import Foundation

// ─── RemoteConfig ─────────────────────────────────────────────────────────────
//
// Fetches API keys from the `get-config` Supabase Edge Function after auth.
// The key lives in Supabase secrets (supabase secrets set GEMINI_API_KEY=…)
// and never touches the app binary or Xcode scheme.
//
// Rotate any key anytime:
//   supabase secrets set GEMINI_API_KEY=<new-key>  (no app update needed)
//
// Falls back to compile-time Secrets.swift if the fetch fails.

final class RemoteConfig: @unchecked Sendable {
    static let shared = RemoteConfig()

    private(set) var geminiAPIKey:   String = Secrets.geminiAPIKey
    private(set) var deepgramAPIKey: String = Secrets.deepgramAPIKey

    private var fetched = false

    private init() {}

    // MARK: - Fetch

    func fetch() async {
        guard !fetched else { return }
        do {
            let config = try await fetchFromEdgeFunction()
            if !config.geminiAPIKey.isEmpty   { geminiAPIKey   = config.geminiAPIKey }
            if !config.deepgramAPIKey.isEmpty { deepgramAPIKey = config.deepgramAPIKey }
            fetched = true
            NousLogger.info("config", "remote config loaded from edge function")
        } catch {
            NousLogger.warning("config", "remote config fetch failed — using compile-time keys",
                               ["err": error.localizedDescription])
        }
    }

    // MARK: - Network

    private struct ConfigResponse: Decodable {
        let geminiAPIKey:   String
        let deepgramAPIKey: String
    }

    private func fetchFromEdgeFunction() async throws -> ConfigResponse {
        guard let token = try? await AuthClient.shared.validAccessToken() else {
            throw URLError(.userAuthenticationRequired)
        }

        let url = AppEnv.supabaseURL
            .appendingPathComponent("/functions/v1/get-config")

        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(AppEnv.supabaseAnonKey, forHTTPHeaderField: "apikey")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(ConfigResponse.self, from: data)
    }
}
