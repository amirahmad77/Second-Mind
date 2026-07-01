import Foundation

/// Minimal Supabase PostgREST client. No SDK dep.
/// Schema expected server-side:
///   table events(id uuid primary key, atom_id uuid, user_id uuid, kind text,
///                payload jsonb, created_at timestamptz)
///   table embeddings(atom_id uuid primary key, user_id uuid, dim int, vector vector(768),
///                    updated_at timestamptz)
///   rpc semantic_search(user_id uuid, query_vector vector, query_text text,
///                       match_count int, decay_lambda_year float, backlink_threshold int)
///   — implements PRD §4: S_final = S_vec * exp(-λ * t_years), neutralized
///     when query_text matches via tsvector OR inbound_links > backlink_threshold.
actor SupabaseClient {
    private let url: URL
    private let anon: String

    init(url: URL = AppEnv.supabaseURL, anon: String = AppEnv.supabaseAnonKey) {
        self.url = url; self.anon = anon
    }

    /// Returns the user's bearer token if a session exists, else the anon key.
    /// PostgREST + RPC calls use this for RLS-aware writes; if you've enabled
    /// RLS on the Supabase tables, anon → no rows. Keep anon as fallback for
    /// pre-auth probe endpoints (none currently).
    private func bearerToken() async -> String {
        if let token = try? await AuthClient.shared.validAccessToken() {
            return token
        }
        return anon
    }

    private func request(_ path: String, method: String = "GET", body: Data? = nil, prefer: String? = nil) async -> URLRequest {
        var req = URLRequest(url: url.appendingPathComponent(path), timeoutInterval: 15)
        req.httpMethod = method
        req.setValue(anon, forHTTPHeaderField: "apikey")
        let token = await bearerToken()
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let prefer { req.setValue(prefer, forHTTPHeaderField: "Prefer") }
        req.httpBody = body
        return req
    }

    /// Insert one event row.
    /// Uses `return=representation` (not `return=minimal`) so we can detect when
    /// Supabase RLS silently blocks the write — a 200 OK with 0 rows returned
    /// means the policy excluded the insert without raising an error. Without this
    /// check, drain() marks the record synced=true and the event is lost forever.
    /// Duplicate events (same id) return HTTP 409 and are treated as success.
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
        let req = await request("rest/v1/events", method: "POST", body: data,
                          prefer: "return=representation")
        let (responseData, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        // 409 = unique-constraint conflict (duplicate event id) — already in Supabase.
        if status == 409 { return }
        try Self.check(resp)
        // A 200/201 with an empty JSON array means RLS blocked the insert without
        // raising an error. Throw so drain() retries with backoff instead of
        // silently marking the record synced.
        if let arr = try? JSONSerialization.jsonObject(with: responseData) as? [[String: Any]],
           arr.isEmpty {
            NousLogger.error("sync", "pushEvent: 0 rows inserted — check Supabase RLS policy on events table",
                             ["eventID": e.id.uuidString, "userID": e.userID.uuidString])
            throw NSError(domain: "Supabase.pushEvent", code: 0,
                          userInfo: [NSLocalizedDescriptionKey:
                            "RLS blocked insert (0 rows returned). Ensure policy: auth.uid() = user_id"])
        }
    }

    /// Pull events authored by the current user since `since` (exclusive).
    /// Used by SyncDaemon to surface server-side captures (Chrome extension,
    /// future web app) into the local SwiftData ledger.
    func fetchEvents(since: Date?, limit: Int = 500) async throws -> [NoteEvent] {
        let uid = await AppEnv.currentUserID()
        var components = URLComponents(url: url.appendingPathComponent("rest/v1/events"),
                                       resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = [
            .init(name: "select", value: "id,atom_id,user_id,kind,payload,created_at"),
            .init(name: "user_id", value: "eq.\(uid.uuidString.lowercased())"),
            .init(name: "order", value: "created_at.asc"),
            .init(name: "limit", value: String(limit)),
        ]
        if let since {
            // Use fractional-second precision so the cursor isn't truncated to whole
            // seconds. Without .withFractionalSeconds, a cursor of T12:00:00.500Z
            // becomes "gt.T12:00:00Z", permanently re-fetching the same sub-second
            // events on every poll cycle.
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            items.append(.init(name: "created_at", value: "gt.\(f.string(from: since))"))
        }
        components.queryItems = items
        guard let fetchURL = components.url else {
            throw NSError(domain: "Supabase.fetchEvents", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "could not build request URL"])
        }
        var req = URLRequest(url: fetchURL, timeoutInterval: 20)
        req.httpMethod = "GET"
        req.setValue(anon, forHTTPHeaderField: "apikey")
        let token = await bearerToken()
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        try Self.check(resp)
        struct Row: Decodable {
            let id: UUID
            let atom_id: UUID
            let user_id: UUID
            let kind: String
            let payload: NoteEventPayload
            let created_at: Date
        }
        // Decode the batch. On failure, fall back to row-by-row so one malformed
        // event doesn't silently discard the entire pull (the old `try? ?? []`
        // pattern would advance no cursor and retry forever on the same bad batch).
        let rows: [Row]
        do {
            rows = try JSONDecoder.nous.decode([Row].self, from: data)
        } catch {
            NousLogger.error("sync", "fetchEvents batch decode failed, falling back to row-by-row",
                             ["error": error.localizedDescription])
            guard let rawArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw error
            }
            rows = rawArray.compactMap { dict in
                guard let rowData = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
                return try? JSONDecoder.nous.decode(Row.self, from: rowData)
            }
        }
        return rows.compactMap { r in
            guard let k = NoteEventKind(rawValue: r.kind) else { return nil }
            return NoteEvent(id: r.id, atomID: r.atom_id, kind: k,
                             payload: r.payload, createdAt: r.created_at, userID: r.user_id)
        }
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
        let uid = await AppEnv.currentUserID()
        let row = Row(atom_id: atomID, user_id: uid,
                      dim: vector.count, vector: vector, updated_at: .now)
        let data = try JSONEncoder.nous.encode([row])
        let req = await request("rest/v1/embeddings", method: "POST", body: data,
                          prefer: "resolution=merge-duplicates,return=minimal")
        let (_, resp) = try await URLSession.shared.data(for: req)
        try Self.check(resp)
    }

    struct SemanticHit: Decodable, Sendable {
        let atom_id: UUID
        /// Decayed score (after λ + overrides applied).
        let score: Double
        /// Pre-decay cosine similarity, surfaced for debugging / future UI.
        let raw_score: Double?
        /// True when decay factor was applied. False when keyword-match or
        /// backlink-count override neutralized decay.
        let decayed: Bool?
        let inbound_links: Int?
        let snippet: String?
        let atom_type: String?
        let created_at: Date?
    }

    /// PRD §4 search. Server-side RPC implements `S_final = S_vec * exp(-λ * t_years)`,
    /// neutralized when `queryText` matches via Postgres tsvector OR the candidate's
    /// `inbound_links > backlinkThreshold`.
    ///
    /// `queryText` should be the user's raw query string — passing it enables the
    /// keyword-override path; passing nil disables it (decay applies uniformly).
    /// Defaults match `Settings` server-side: λ=0.21072 (~10% decay / 6 months),
    /// backlink threshold=3.
    ///
    /// Returns `[]` on any non-200 (network down, RPC schema mismatch, etc) so the
    /// caller can fall back to lexical without surfacing errors to the user.
    func semanticSearch(
        queryVector: [Float],
        queryText: String? = nil,
        limit: Int = 20,
        decayLambdaYear: Double = 0.21072,
        backlinkThreshold: Int = 3
    ) async throws -> [SemanticHit] {
        struct Args: Encodable {
            let user_id: UUID
            let query_vector: [Float]
            let query_text: String?
            let match_count: Int
            let decay_lambda_year: Double
            let backlink_threshold: Int
        }
        let uid = await AppEnv.currentUserID()
        let args = Args(
            user_id: uid,
            query_vector: queryVector,
            query_text: queryText,
            match_count: limit,
            decay_lambda_year: decayLambdaYear,
            backlink_threshold: backlinkThreshold
        )
        let data = try JSONEncoder.nous.encode(args)
        let req = await request("rest/v1/rpc/semantic_search", method: "POST", body: data)
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
