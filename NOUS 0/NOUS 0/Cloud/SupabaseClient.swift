import Foundation

/// Minimal Supabase PostgREST client. No SDK dep.
/// Schema expected server-side:
///   table events(id uuid primary key, atom_id uuid, user_id uuid, kind text,
///                payload jsonb, created_at timestamptz)
///   table embeddings(atom_id uuid primary key, user_id uuid, dim int, vector vector(768),
///                    updated_at timestamptz)
///   rpc semantic_search(user_id uuid, query_vector vector, match_count int, decay_lambda float)
actor SupabaseClient {
    private let url: URL
    private let anon: String

    init(url: URL = AppEnv.supabaseURL, anon: String = AppEnv.supabaseAnonKey) {
        self.url = url; self.anon = anon
    }

    private func request(_ path: String, method: String = "GET", body: Data? = nil, prefer: String? = nil) -> URLRequest {
        var req = URLRequest(url: url.appendingPathComponent(path), timeoutInterval: 15)
        req.httpMethod = method
        req.setValue(anon, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(anon)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let prefer { req.setValue(prefer, forHTTPHeaderField: "Prefer") }
        req.httpBody = body
        return req
    }

    /// Insert one event row. Idempotent via `Prefer: resolution=ignore-duplicates` on id.
    func pushEvent(_ e: NoteEvent) async throws {
        struct Row: Encodable {
            let id: UUID
            let atom_id: UUID
            let user_id: UUID
            let kind: String
            let payload: NoteEventPayload
            let created_at: Date
        }
        let row = Row(id: e.id, atom_id: e.atomID, user_id: e.userID,
                      kind: e.kind.rawValue, payload: e.payload, created_at: e.createdAt)
        let data = try JSONEncoder.nous.encode([row])
        let req = request("rest/v1/events", method: "POST", body: data,
                          prefer: "resolution=ignore-duplicates,return=minimal")
        let (_, resp) = try await URLSession.shared.data(for: req)
        try Self.check(resp)
    }

    /// Upsert embedding.
    func upsertEmbedding(atomID: UUID, vector: [Float]) async throws {
        struct Row: Encodable {
            let atom_id: UUID
            let user_id: UUID
            let dim: Int
            let vector: [Float]
            let updated_at: Date
        }
        let row = Row(atom_id: atomID, user_id: AppEnv.localUserID,
                      dim: vector.count, vector: vector, updated_at: .now)
        let data = try JSONEncoder.nous.encode([row])
        let req = request("rest/v1/embeddings", method: "POST", body: data,
                          prefer: "resolution=merge-duplicates,return=minimal")
        let (_, resp) = try await URLSession.shared.data(for: req)
        try Self.check(resp)
    }

    struct SemanticHit: Decodable, Sendable {
        let atom_id: UUID
        let score: Double
        let snippet: String?
    }

    /// Calls RPC. If not present server-side, returns []. Client falls back to lexical.
    func semanticSearch(queryVector: [Float], limit: Int = 20, decayLambda: Double = 0.14) async throws -> [SemanticHit] {
        struct Args: Encodable {
            let user_id: UUID
            let query_vector: [Float]
            let match_count: Int
            let decay_lambda: Double
        }
        let args = Args(user_id: AppEnv.localUserID, query_vector: queryVector,
                        match_count: limit, decay_lambda: decayLambda)
        let data = try JSONEncoder.nous.encode(args)
        let req = request("rest/v1/rpc/semantic_search", method: "POST", body: data)
        let (payload, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        return (try? JSONDecoder.nous.decode([SemanticHit].self, from: payload)) ?? []
    }

    private static func check(_ resp: URLResponse) throws {
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "Supabase", code: (resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
    }
}
