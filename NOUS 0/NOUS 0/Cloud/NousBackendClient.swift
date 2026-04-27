import Foundation

/// Client for the NOUS FastAPI backend (synthesis + pushback + search).
///
/// Streaming endpoints emit Server-Sent Events with named channels matching
/// `app/sse.py` on the backend:
///   - `update`   { stage, detail? }
///   - `citation` { atom_id, snippet, score }   // synthesize only
///   - `token`    { text }
///   - `done`     {}
///   - `error`    { code, message }
///
/// Consumers use `AsyncThrowingStream<NousSSEEvent>` returned by `synthesize` /
/// `pushback`. The stream completes naturally on `done` or throws on `error`.
actor NousBackendClient {
    private let baseURL: URL?
    private let session: URLSession

    init(baseURL: URL? = AppEnv.nousBackendURL,
         session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    /// True iff a backend URL is configured. Use to gate UI features.
    var isConfigured: Bool { baseURL != nil }

    // MARK: - Wire types

    enum NousSSEEvent: Sendable, Equatable {
        case update(stage: String, detail: String?)
        case citation(atomID: UUID, snippet: String, score: Double)
        case token(String)
        /// Terminal event. Stream ends after this is yielded.
        case done
    }

    enum BackendError: Error, LocalizedError {
        case notConfigured
        case http(Int, String)
        case stream(String)
        case decoding(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: "NOUS backend URL not configured in app settings"
            case .http(let code, let msg): "HTTP \(code): \(msg)"
            case .stream(let m): "Stream error: \(m)"
            case .decoding(let m): "Decode error: \(m)"
            }
        }
    }

    struct SearchHit: Decodable, Sendable, Identifiable {
        let atom_id: UUID
        let score: Double
        let raw_score: Double
        let decayed: Bool
        let inbound_links: Int
        let content: String
        let atom_type: String
        let created_at: Date
        let tags: [String]
        var id: UUID { atom_id }
    }

    struct SearchResponse: Decodable, Sendable {
        let query: String
        let hits: [SearchHit]
        let decay_lambda_year: Double
        let backlink_threshold: Int
    }

    // MARK: - Suggest links (non-streaming)

    struct SuggestLinksResponse: Decodable, Sendable {
        let source_atom_id: UUID
        let suggestions: [Suggestion]
        let candidate_count: Int

        struct Suggestion: Decodable, Sendable, Hashable {
            let atom_id: UUID
            let reason: String
            let score: Double
        }
    }

    func suggestLinks(userID: UUID,
                      atomID: UUID,
                      text: String,
                      candidatePool: Int = 10,
                      maxPicks: Int = 3) async throws -> SuggestLinksResponse {
        guard let baseURL else { throw BackendError.notConfigured }
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/suggest-links"),
                             timeoutInterval: 25)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder.iso.encode([
            "user_id": AnyEncodable(userID.uuidString),
            "atom_id": AnyEncodable(atomID.uuidString),
            "text": AnyEncodable(text),
            "candidate_pool": AnyEncodable(candidatePool),
            "max_picks": AnyEncodable(maxPicks)
        ])
        let (data, resp) = try await session.data(for: req)
        try Self.checkOK(resp, data: data)
        return try JSONDecoder.iso.decode(SuggestLinksResponse.self, from: data)
    }

    // MARK: - Active Meet sessions (iOS status polling)

    struct ActiveMeetSession: Decodable, Sendable, Identifiable {
        let meet_id: String
        let participants: [String]
        let started_at: Date?
        let segment_count: Int
        var id: String { meet_id }

        /// Display-ready participant list, max 3 names.
        var participantSummary: String {
            let names = participants.prefix(3)
            if names.isEmpty { return "" }
            let joined = names.joined(separator: ", ")
            return participants.count > 3 ? "\(joined) +\(participants.count - 3)" : joined
        }
    }

    private struct ActiveMeetsResponse: Decodable, Sendable {
        let sessions: [ActiveMeetSession]
    }

    func activeMeetSessions(userID: UUID) async throws -> [ActiveMeetSession] {
        guard let baseURL else { throw BackendError.notConfigured }
        var comps = URLComponents(url: baseURL.appendingPathComponent("v1/meet/active"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "user_id", value: userID.uuidString)]
        guard let url = comps.url else { throw BackendError.notConfigured }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "GET"
        let (data, resp) = try await session.data(for: req)
        try Self.checkOK(resp, data: data)
        return try JSONDecoder.iso.decode(ActiveMeetsResponse.self, from: data).sessions
    }

    // MARK: - Pairing (extension onboarding)

    struct PairStartResponse: Decodable, Sendable {
        let code: String
        let expires_at: Date
    }

    func pairStart(userID: UUID) async throws -> PairStartResponse {
        guard let baseURL else { throw BackendError.notConfigured }
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/pair/start"),
                             timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder.iso.encode([
            "user_id": AnyEncodable(userID.uuidString)
        ])
        let (data, resp) = try await session.data(for: req)
        try Self.checkOK(resp, data: data)
        return try JSONDecoder.iso.decode(PairStartResponse.self, from: data)
    }

    // MARK: - Search (non-streaming)

    func search(userID: UUID, query: String, limit: Int = 20) async throws -> SearchResponse {
        guard let baseURL else { throw BackendError.notConfigured }
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/search"),
                             timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder.iso.encode([
            "user_id": AnyEncodable(userID.uuidString),
            "query": AnyEncodable(query),
            "limit": AnyEncodable(limit)
        ])
        let (data, resp) = try await session.data(for: req)
        try Self.checkOK(resp, data: data)
        return try JSONDecoder.iso.decode(SearchResponse.self, from: data)
    }

    // MARK: - Compose (SSE)

    func compose(userID: UUID,
                 intent: String,
                 atomIDs: [UUID],
                 tone: String = "post") async throws -> AsyncThrowingStream<NousSSEEvent, Error> {
        guard let baseURL else { throw BackendError.notConfigured }
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/compose"),
                             timeoutInterval: 0)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        // Build body with array support — AnyEncodable is scalar-only, so encode by hand.
        struct Body: Encodable {
            let user_id: String
            let intent: String
            let atom_ids: [String]
            let tone: String
        }
        req.httpBody = try JSONEncoder.iso.encode(Body(
            user_id: userID.uuidString,
            intent: intent,
            atom_ids: atomIDs.map(\.uuidString),
            tone: tone
        ))
        return try await openSSE(req)
    }

    // MARK: - Synthesize (SSE)

    func synthesize(userID: UUID,
                    question: String,
                    contextLimit: Int = 12) async throws -> AsyncThrowingStream<NousSSEEvent, Error> {
        guard let baseURL else {
            NousLogger.error("synthesis", "not configured — NOUS_BACKEND_URL missing")
            throw BackendError.notConfigured
        }
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/synthesize"),
                             timeoutInterval: 0) // streaming — no overall timeout
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONEncoder.iso.encode([
            "user_id": AnyEncodable(userID.uuidString),
            "question": AnyEncodable(question),
            "context_limit": AnyEncodable(contextLimit)
        ])
        return try await openSSE(req)
    }

    // MARK: - Pushback (SSE; tokens carry JSONL items)

    struct PushbackItem: Decodable, Sendable, Identifiable {
        let kind: String         // contradiction|gap|question|assumption|thread
        let prompt: String
        let atom_ids: [UUID]
        let confidence: Double
        var id: String { "\(kind)-\(prompt.hashValue)" }
    }

    func pushback(userID: UUID,
                  sinceDays: Int = 14,
                  maxAtoms: Int = 30) async throws -> AsyncThrowingStream<NousSSEEvent, Error> {
        guard let baseURL else { throw BackendError.notConfigured }
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/pushback"),
                             timeoutInterval: 0)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONEncoder.iso.encode([
            "user_id": AnyEncodable(userID.uuidString),
            "since_days": AnyEncodable(sinceDays),
            "max_atoms": AnyEncodable(maxAtoms)
        ])
        return try await openSSE(req)
    }

    /// Convenience: drains a pushback stream and parses JSONL `token` events into items.
    func pushbackItems(userID: UUID,
                       sinceDays: Int = 14,
                       maxAtoms: Int = 30) async throws -> [PushbackItem] {
        let stream = try await pushback(userID: userID, sinceDays: sinceDays, maxAtoms: maxAtoms)
        var buffer = ""
        var items: [PushbackItem] = []
        for try await ev in stream {
            switch ev {
            case .token(let t): buffer += t
            case .done: break
            default: continue
            }
        }
        for line in buffer.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8) else { continue }
            if let item = try? JSONDecoder.iso.decode(PushbackItem.self, from: data) {
                items.append(item)
            }
        }
        return items
    }

    // MARK: - SSE plumbing

    private func openSSE(_ req: URLRequest) async throws -> AsyncThrowingStream<NousSSEEvent, Error> {
        let (bytes, resp) = try await session.bytes(for: req)
        try Self.checkOK(resp)

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var currentEvent = "message"
                    var dataBuffer = ""

                    for try await rawLine in bytes.lines {
                        // SSE: blank line = dispatch buffered event.
                        if rawLine.isEmpty {
                            try Self.dispatch(event: currentEvent,
                                              data: dataBuffer,
                                              into: continuation)
                            currentEvent = "message"
                            dataBuffer = ""
                            continue
                        }
                        if rawLine.hasPrefix(":") { continue } // SSE comment
                        if let v = rawLine.dropPrefix("event:") {
                            currentEvent = v.trimmingCharacters(in: .whitespaces)
                        } else if let v = rawLine.dropPrefix("data:") {
                            if !dataBuffer.isEmpty { dataBuffer += "\n" }
                            dataBuffer += v.drop(while: { $0 == " " })
                        }
                        // ignore id:, retry:
                    }
                    // Stream ended without explicit `done` — emit one for parity.
                    continuation.yield(.done)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func dispatch(event: String,
                                 data: String,
                                 into c: AsyncThrowingStream<NousSSEEvent, Error>.Continuation) throws {
        guard !data.isEmpty else { return }
        let json = data.data(using: .utf8) ?? Data()

        switch event {
        case "update":
            struct U: Decodable { let stage: String; let detail: String? }
            let u = try JSONDecoder.iso.decode(U.self, from: json)
            c.yield(.update(stage: u.stage, detail: u.detail))

        case "citation":
            struct CI: Decodable { let atom_id: UUID; let snippet: String; let score: Double }
            let ci = try JSONDecoder.iso.decode(CI.self, from: json)
            c.yield(.citation(atomID: ci.atom_id, snippet: ci.snippet, score: ci.score))

        case "token":
            struct T: Decodable { let text: String }
            let t = try JSONDecoder.iso.decode(T.self, from: json)
            c.yield(.token(t.text))

        case "done":
            c.yield(.done)
            c.finish()

        case "error":
            struct E: Decodable { let code: String; let message: String }
            let e = try JSONDecoder.iso.decode(E.self, from: json)
            c.finish(throwing: BackendError.stream("\(e.code): \(e.message)"))

        default:
            // Unknown event channel — ignore forward-compat.
            break
        }
    }

    private static func checkOK(_ resp: URLResponse, data: Data? = nil) throws {
        guard let http = resp as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            throw BackendError.http(http.statusCode, body)
        }
    }
}

// MARK: - Helpers

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

private extension String {
    /// Returns the substring after `prefix` if present, else nil.
    func dropPrefix(_ prefix: String) -> Substring? {
        hasPrefix(prefix) ? self.dropFirst(prefix.count) : nil
    }
}

/// Type-erased Encodable for ad-hoc dictionary bodies.
private struct AnyEncodable: Encodable {
    let value: Any
    init(_ value: Any) { self.value = value }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case let v as String: try c.encode(v)
        case let v as Int:    try c.encode(v)
        case let v as Double: try c.encode(v)
        case let v as Bool:   try c.encode(v)
        default:
            throw EncodingError.invalidValue(value,
                .init(codingPath: encoder.codingPath, debugDescription: "unsupported"))
        }
    }
}
