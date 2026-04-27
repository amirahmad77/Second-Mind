import Foundation

/// Minimal Gemini REST client (generativelanguage.googleapis.com, v1beta).
/// Uses API key in query string. No SDK dep.
actor GeminiClient {
    private let apiKey: String
    // Cap total response time. URLRequest.timeoutInterval only guards the first byte;
    // without timeoutIntervalForResource the download itself has no deadline (URLSession
    // default is 7 days), which lets slow/thinking-mode models hang isRefining forever.
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest  = 20  // first byte
        cfg.timeoutIntervalForResource = 45  // full response
        return URLSession(configuration: cfg)
    }()

    init(apiKey: String = AppEnv.geminiAPIKey) { self.apiKey = apiKey }

    // MARK: Refine

    /// Result of one refine call: cleaned markdown body + 0–7 tags + detected type.
    /// All fields arrive in one JSON envelope — no extra roundtrip.
    struct RefineResult: Sendable {
        let refined: String
        let tags: [String]
        let type: AtomType?   // nil only if Gemini returns an unrecognised value (safe to ignore)
    }

    /// Refines raw text into clean markdown AND extracts smart tags.
    /// Returns parsed JSON `{ refined: String, tags: [String] }` per the schema below.
    /// Tags are normalized (lowercase, hyphenated, deduped, capped at 7) before return.
    func refine(raw: String, type: AtomType = .thought) async throws -> RefineResult {
        guard !apiKey.isEmpty else {
            NousLogger.error("gemini", "refine skipped — NOUS_GEMINI_API_KEY not set")
            throw NSError(domain: "Gemini", code: -99,
                          userInfo: [NSLocalizedDescriptionKey: "API key not configured"])
        }
        // Generic JSON request shape — Gemini structured output via responseSchema.
        let body: [String: Any] = [
            "systemInstruction": [
                "role": "system",
                "parts": [["text": Self.prompt(for: type)]]
            ],
            "contents": [
                ["role": "user", "parts": [["text": raw]]]
            ],
            "generationConfig": [
                "temperature": 0.2,
                "responseMimeType": "application/json",
                "responseSchema": [
                    "type": "OBJECT",
                    "properties": [
                        "refined": ["type": "STRING"],
                        "tags": [
                            "type": "ARRAY",
                            "items": ["type": "STRING"],
                            "maxItems": 7
                        ],
                        "type": [
                            "type": "STRING",
                            "enum": ["thought", "task", "meeting", "decision", "question", "reference"]
                        ]
                    ],
                    "required": ["refined", "tags", "type"]
                ]
            ]
        ]

        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(AppEnv.geminiRefineModel):generateContent")!
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            NousLogger.error("gemini", "refine HTTP \(status)", ["model": AppEnv.geminiRefineModel, "body": String(body.prefix(400))])
            throw NSError(domain: "Gemini.refine", code: status,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(status): \(body.prefix(200))"])
        }

        struct Part: Decodable { let text: String? }
        struct Content: Decodable { let parts: [Part]? }
        struct Cand: Decodable { let content: Content? }
        struct Resp: Decodable { let candidates: [Cand]? }
        let envelope = try JSONDecoder().decode(Resp.self, from: data)
        let payloadText = envelope.candidates?.first?.content?.parts?.compactMap(\.text).joined() ?? ""

        struct Inner: Decodable { let refined: String; let tags: [String]?; let type: String? }
        guard let payloadData = payloadText.data(using: .utf8), !payloadText.isEmpty else {
            NousLogger.error("gemini", "refine empty payload", ["candidates": envelope.candidates?.count ?? 0])
            throw NSError(domain: "Gemini.refine", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "empty payload"])
        }
        let inner = try JSONDecoder().decode(Inner.self, from: payloadData)

        let refined = inner.refined.trimmingCharacters(in: .whitespacesAndNewlines)
        let tags = TagNormalizer.normalize(inner.tags ?? [])
        let detectedType = inner.type.flatMap { AtomType(rawValue: $0) }
        NousLogger.info("gemini", "refine ok", ["hint": type.rawValue, "detected": detectedType?.rawValue ?? "nil", "tags": tags.count, "len": refined.count])
        return RefineResult(refined: refined, tags: tags, type: detectedType)
    }

    // MARK: Analyze edit (refine + task extraction)

    struct ExtractedTask: Sendable {
        let text: String    // "- [ ] buy temperature device"
        let dueISO: String? // "2026-04-29" or nil
    }

    struct AnalysisResult: Sendable {
        let refined: String
        let tags: [String]
        let extractedTasks: [ExtractedTask]
    }

    /// Re-refine edited content AND extract any actionable tasks buried in it.
    /// The atom type governs how the main content is refined; task extraction
    /// happens regardless of type (a thought can contain an embedded task).
    func analyzeEdit(raw: String, type: AtomType) async throws -> AnalysisResult {
        let today = { () -> String in
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
            return f.string(from: Date())
        }()

        let body: [String: Any] = [
            "systemInstruction": [
                "role": "system",
                "parts": [["text": Self.analysisPrompt(for: type, today: today)]]
            ],
            "contents": [
                ["role": "user", "parts": [["text": raw]]]
            ],
            "generationConfig": [
                "temperature": 0.2,
                "responseMimeType": "application/json",
                "responseSchema": [
                    "type": "OBJECT",
                    "properties": [
                        "refined": ["type": "STRING"],
                        "tags": [
                            "type": "ARRAY",
                            "items": ["type": "STRING"],
                            "maxItems": 7
                        ],
                        "extractedTasks": [
                            "type": "ARRAY",
                            "items": [
                                "type": "OBJECT",
                                "properties": [
                                    "text": ["type": "STRING"],
                                    "dueISO": ["type": "STRING", "nullable": true]
                                ],
                                "required": ["text", "dueISO"]
                            ]
                        ]
                    ],
                    "required": ["refined", "tags", "extractedTasks"]
                ]
            ]
        ]

        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(AppEnv.geminiRefineModel):generateContent")!
        var req = URLRequest(url: url, timeoutInterval: 25)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await session.data(for: req)
        let aeStatus = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard aeStatus == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            NousLogger.error("gemini", "analyzeEdit HTTP \(aeStatus)", ["model": AppEnv.geminiRefineModel, "body": String(body.prefix(400))])
            throw NSError(domain: "Gemini.analyzeEdit", code: aeStatus,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(aeStatus): \(body.prefix(200))"])
        }

        struct Part: Decodable { let text: String? }
        struct Content: Decodable { let parts: [Part]? }
        struct Cand: Decodable { let content: Content? }
        struct Resp: Decodable { let candidates: [Cand]? }
        let envelope = try JSONDecoder().decode(Resp.self, from: data)
        let payloadText = envelope.candidates?.first?.content?.parts?.compactMap(\.text).joined() ?? ""

        struct RawTask: Decodable { let text: String; let dueISO: String? }
        struct Inner: Decodable { let refined: String; let tags: [String]?; let extractedTasks: [RawTask]? }
        guard let payloadData = payloadText.data(using: .utf8), !payloadText.isEmpty else {
            throw NSError(domain: "Gemini.analyzeEdit", code: -2)
        }
        let inner = try JSONDecoder().decode(Inner.self, from: payloadData)
        let refined = inner.refined.trimmingCharacters(in: .whitespacesAndNewlines)
        let tags = TagNormalizer.normalize(inner.tags ?? [])
        let tasks = (inner.extractedTasks ?? []).map { t in
            ExtractedTask(text: t.text, dueISO: t.dueISO.flatMap { $0.isEmpty ? nil : $0 })
        }
        return AnalysisResult(refined: refined, tags: tags, extractedTasks: tasks)
    }

    private static func analysisPrompt(for type: AtomType, today: String) -> String {
        """
        You analyze edited atom content for an atom of type: \(type.rawValue.uppercased()).

        STEP 1 — REFINE the full content:
        \(refineSummary(for: type))

        STEP 2 — EXTRACT TASKS: Scan for clearly action-oriented sentences.
        Extract only if explicitly actionable (to buy, do, call, schedule, send, check, build, etc.).
        Skip philosophical observations, general advice, or vague intentions.
        - Format each as: "- [ ] <concise action>"
        - Parse due dates relative to TODAY: \(today).
          "today" → \(today). "tomorrow" → day after. "next week" → next Monday.
          "by <weekday>" → the upcoming named day. Return YYYY-MM-DD, or null if no date.
        - Max 5 tasks. Return [] if none found.

        \(tagRules)

        Output JSON: { "refined": string, "tags": string[], "extractedTasks": [{ "text": string, "dueISO": string|null }] }
        """
    }

    private static func refineSummary(for type: AtomType) -> String {
        switch type {
        case .thought:
            return """
            First line: core insight as a stream-ready headline (≤90 chars, no filler). \
            Body: 1–3 lines with **bold** key terms; prose default, bullets for 3+ items. ≤150 words.
            """
        case .task:
            return """
            First line: specific group title or single-action name (no `- [ ]` prefix). \
            Body: one `- [ ] <action>` per step. Preserve exact wording.
            """
        case .question:
            return """
            First line: sharpened question ending with '?'. \
            Body: 2–3 exploration `- ` bullets. ≤100 words.
            """
        case .meeting:
            return """
            First line: `<topic> — <key outcome>` (≤90 chars). \
            Body: ## decisions / ## action items / ## open questions. Omit empty sections. ≤250 words.
            """
        case .decision:
            return """
            First line: `Decided: <specific decision>` (≤80 chars). \
            Body: **Why:** rationale + alternatives bullets. ≤120 words.
            """
        case .reference:
            return """
            First line: descriptive title naming what this reference is (≤80 chars). \
            Body: 1–3 context lines, preserve URLs, `> ` for key quotes. ≤120 words.
            """
        }
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
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(AppEnv.geminiEmbedModel):embedContent")!
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        req.httpBody = try JSONEncoder.nous.encode(body)

        let (data, resp) = try await session.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(domain: "Gemini.embed", code: (resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let decoded = try JSONDecoder.nous.decode(Resp.self, from: data)
        return decoded.embedding.values
    }

    // MARK: - Type-specific system prompts

    private static func prompt(for type: AtomType) -> String {
        switch type {
        case .thought:   return thoughtPrompt
        case .task:      return taskPrompt
        case .question:  return questionPrompt
        case .meeting:   return meetingPrompt
        case .decision:  return decisionPrompt
        case .reference: return referencePrompt
        }
    }

    private static let tagRules = """
    TAGS: 3–7 tags mixing topic, entity (person/project/product), and semantic kind. \
    Lowercase, hyphen-separated, no #, no emoji. Skip verb-only tags or tags that restate \
    the atom type. Return [] if the input is too short or trivial.
    """

    private static let streamHeadlineRule = """
    STREAM HEADLINE (first line): This line appears alone as the atom preview in a feed. \
    It must be self-contained, specific, and meaningful with zero surrounding context. \
    No filler ("This is about…", "Here is…", "Note:"), no labels, no trailing punctuation \
    except ? for questions. Write it like a sharp news headline or a journal entry's \
    opening sentence — the reader should know exactly what the atom is about after \
    reading it in isolation. ≤90 chars.
    """

    // Used for all initial captures (type=.thought). Detects the true type THEN
    // formats according to that type. Single roundtrip — classification is free.
    private static let thoughtPrompt = """
    You classify and refine raw captured notes for a personal knowledge system.

    STEP 1 — CLASSIFY the content. Set `type` to the best match:
    - "thought"   → insight, observation, idea, reflection, anything else
    - "task"      → todo, action item, something to buy/do/send/call
    - "meeting"   → meeting notes, attendees, discussion record
    - "decision"  → something decided, chosen, or committed to
    - "question"  → open question, uncertainty, thing to investigate
    - "reference" → URL, saved resource, article, book, tool, paper

    STEP 2 — FORMAT using the rules for the detected type:

    If thought:
    \(streamHeadlineRule)
    Body: 1–3 lines expanding why it matters. **bold** 1–2 key terms. Prose default, `- ` bullets for 3+ items. `> ` for quotes. ≤150 words.

    If task:
    First line = group title or single-action name (≤60 chars, no `- [ ]` prefix).
    Body: `- [ ] <action>` per step. Preserve exact wording.

    If question:
    First line = sharpened question ending with "?". Body: 2–3 `- ` exploration bullets. ≤100 words.

    If meeting:
    First line = `<topic> — <key outcome>` (≤90 chars).
    Body: ## decisions / ## action items / ## open questions. Omit empty sections. ≤250 words.

    If decision:
    First line = `Decided: <what was decided>` (≤80 chars).
    Body: **Why:** rationale + alternatives bullets. ≤120 words.

    If reference:
    First line = descriptive title naming what was saved (≤80 chars).
    Body: 1–3 context lines, preserve URLs, `> ` for key quotes. ≤120 words.

    \(tagRules)
    """

    private static let taskPrompt = """
    You refine raw captured tasks and to-dos into clean, actionable checklists.
    Output: { "refined": string, "tags": string[], "type": "task" }

    STREAM HEADLINE (first line):
    - Single action: write the action directly — no `- [ ]` prefix on this line. \
      The checklist item on line 2+ carries the checkbox.
    - Multiple actions: write a short group title that names the task cluster (≤60 chars). \
      No verb-only titles ("Tasks", "Todo") — be specific ("Set up auth flow", "Q2 launch prep").
    - This line is the stream preview, so it must be meaningful alone.

    BODY (lines 2+):
    - One `- [ ] <action>` per step.
    - Preserve the author's exact wording per action item.
    - Never invent sub-tasks that weren't implied.
    - Single-action atoms: the body IS the `- [ ] <action>` line, preceded by the headline.

    TAGS: 2–5 tags. Topic + project/area. Skip pure action verbs.
    """

    private static let questionPrompt = """
    You refine raw questions and uncertainties into structured inquiries.
    Output: { "refined": string, "tags": string[], "type": "question" }

    \(streamHeadlineRule)
    The headline IS the sharpened question. End with "?". Preserve the author's core phrasing.

    BODY (lines 2+, optional):
    - 2–3 compact `- ` bullets: angles to explore, what a good answer looks like, related tensions.
    - Never invent answers or assert conclusions.
    - Total ≤100 words.

    \(tagRules)
    """

    private static let meetingPrompt = """
    You refine raw meeting notes into a structured, scannable summary.
    Output: { "refined": string, "tags": string[], "type": "meeting" }

    STREAM HEADLINE (first line): `<topic> — <key outcome or status>` (≤90 chars). \
    Examples: "Pricing review — decided to ship freemium tier", \
    "1:1 with Alex — unblocked on auth, needs design review". \
    Must name what the meeting was about AND its most important outcome.

    BODY (lines 2+):
    - `## decisions` — concrete decisions made, one `- ` bullet each. Omit if none.
    - `## action items` — `- [ ] <item>` per action. Omit if none.
    - `## open questions` — unresolved threads as `- ` bullets. Omit if none.
    - Omit empty sections entirely. Total ≤250 words.

    TAGS: 3–6 tags. Project, people present, topic.
    """

    private static let decisionPrompt = """
    You refine raw decision records into clear, durable log entries.
    Output: { "refined": string, "tags": string[], "type": "decision" }

    STREAM HEADLINE (first line): `Decided: <what was decided>` (≤80 chars). \
    Be specific enough to understand the decision without further context. \
    Bad: "Decided: go with option B". Good: "Decided: use Supabase Auth over custom JWT".

    BODY (lines 2+, optional):
    - **Why:** 1–2 lines of rationale.
    - Alternatives considered: `- ` bullets if relevant (2 max).
    - Preserve exact wording for the decision itself. Never invent rationale.
    - Total ≤120 words.

    \(tagRules)
    """

    private static let referencePrompt = """
    You refine a raw reference or resource note into a titled, scannable entry.
    Output: { "refined": string, "tags": string[], "type": "reference" }

    STREAM HEADLINE (first line): A descriptive title that names what this reference IS (≤80 chars). \
    No prefix. Examples: "Supabase RLS row-level security guide", \
    "Paul Graham — Keep Your Identity Small (essay)". \
    The reader must understand what they saved without opening it.

    BODY (lines 2+):
    - 1–3 compact lines: what it covers, why it was saved, key takeaway or quote.
    - Preserve any URL exactly as given.
    - If a key quote exists, use `> ` blockquote syntax.
    - Total ≤120 words.

    TAGS: 3–6 tags. Topic, domain, format (article, video, tool, paper, book, etc.).
    """
}

// MARK: - Tag normalization

enum TagNormalizer {
    /// Lowercase, collapse whitespace → hyphens, strip non-`[a-z0-9-]`, dedupe, cap 7.
    static func normalize(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for r in raw {
            let n = normalizeOne(r)
            guard !n.isEmpty, !seen.contains(n) else { continue }
            seen.insert(n)
            out.append(n)
            if out.count >= 7 { break }
        }
        return out
    }

    static func normalizeOne(_ raw: String) -> String {
        var s = raw.lowercased()
        // Strip leading hashes / hash-like noise
        while s.hasPrefix("#") { s.removeFirst() }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // Replace any whitespace run with a single hyphen
        s = s.split(whereSeparator: { $0.isWhitespace }).joined(separator: "-")
        // Strip everything except a-z 0-9 -
        s = s.unicodeScalars
            .filter { ("a"..."z").contains(Character($0)) || ("0"..."9").contains(Character($0)) || $0 == "-" }
            .map { String($0) }
            .joined()
        // Collapse runs of -
        while s.contains("--") { s = s.replacingOccurrences(of: "--", with: "-") }
        // Trim leading/trailing -
        while s.hasPrefix("-") { s.removeFirst() }
        while s.hasSuffix("-") { s.removeLast() }
        return s
    }
}
