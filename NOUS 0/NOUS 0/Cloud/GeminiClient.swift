import Foundation

/// Minimal Gemini REST client (generativelanguage.googleapis.com, v1beta).
/// Uses API key in query string. No SDK dep.
actor GeminiClient {
    private let apiKey: String
    init(apiKey: String = AppEnv.geminiAPIKey) { self.apiKey = apiKey }

    // MARK: Refine

    /// Refines raw text into clean markdown. Returns nil on non-success.
    func refine(raw: String) async throws -> String {
        struct Part: Codable { let text: String }
        struct Content: Codable { let role: String?; let parts: [Part] }
        struct GenCfg: Codable { let temperature: Double; let responseMimeType: String }
        struct Req: Codable {
            let systemInstruction: Content
            let contents: [Content]
            let generationConfig: GenCfg
        }
        struct Cand: Decodable { let content: Content? }
        struct Resp: Decodable { let candidates: [Cand]? }

        let sys = Content(role: "system", parts: [Part(text: Self.refinePrompt)])
        let user = Content(role: "user", parts: [Part(text: raw)])
        let body = Req(systemInstruction: sys, contents: [user],
                       generationConfig: GenCfg(temperature: 0.2, responseMimeType: "text/plain"))

        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(AppEnv.geminiRefineModel):generateContent?key=\(apiKey)")!
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder.nous.encode(body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(domain: "Gemini.refine", code: (resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let decoded = try JSONDecoder.nous.decode(Resp.self, from: data)
        let text = decoded.candidates?.first?.content?.parts.map(\.text).joined() ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Embed

    /// Returns 768-dim vector (MRL truncated) or nil.
    func embed(_ text: String) async throws -> [Float] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else {
            throw NSError(domain: "Gemini.embed", code: -2)
        }
        // Gemini embed input cap ~2048 tokens ≈ 8KB chars. Truncate defensively.
        let input = trimmed.count > 8000 ? String(trimmed.prefix(8000)) : trimmed
        struct Part: Codable { let text: String }
        struct Content: Codable { let parts: [Part] }
        struct Req: Codable {
            let content: Content
            let outputDimensionality: Int
            let taskType: String
        }
        struct Emb: Decodable { let values: [Float] }
        struct Resp: Decodable { let embedding: Emb }

        let body = Req(content: Content(parts: [Part(text: input)]),
                       outputDimensionality: AppEnv.embedDim,
                       taskType: "SEMANTIC_SIMILARITY")
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(AppEnv.geminiEmbedModel):embedContent?key=\(apiKey)")!
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder.nous.encode(body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(domain: "Gemini.embed", code: (resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let decoded = try JSONDecoder.nous.decode(Resp.self, from: data)
        return decoded.embedding.values
    }

    private static let refinePrompt = """
    You refine raw captured thoughts into clean, minimal Markdown.
    Rules:
    - Preserve the author's exact wording wherever possible.
    - Never invent facts, links, numbers, names, or dates.
    - Fix only: obvious typos, punctuation, sentence case, paragraph breaks.
    - Use minimal markdown: # H1 only for explicit titles; bullet lists only if content is clearly a list; task bullets as `- [ ]`.
    - Output plain text (markdown). No code fences, no preface, no explanation.
    - If input is already clean or too short, return it unchanged.
    - Keep length within ±15% of input.
    """
}
