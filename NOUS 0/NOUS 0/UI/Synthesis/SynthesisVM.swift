import Foundation
import Observation
import SwiftData

/// Drives a synthesis session: embed question → local cosine search → Gemini answer.
/// All network calls go directly to Gemini — no external backend required.
@Observable
@MainActor
final class SynthesisVM {

    enum Stage: Equatable {
        case idle
        case embedding
        case retrieving
        case synthesizing
        case done
        case failed(String)
    }

    struct Citation: Identifiable, Hashable {
        let id: UUID
        let snippet: String
        let score: Double
    }

    var question: String = ""
    private(set) var stage: Stage = .idle
    private(set) var answer: String = ""
    private(set) var citations: [Citation] = []

    var canSubmit: Bool {
        question.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2
            && stage.isInteractive
    }
    var isStreaming: Bool {
        switch stage {
        case .embedding, .retrieving, .synthesizing: return true
        default: return false
        }
    }

    private let gemini: GeminiClient
    private let store: AtomStore
    private let fetchEmbeddings: @MainActor () -> [(atomID: UUID, vector: [Float])]
    private var task: Task<Void, Never>?
    private var submitTime: Date?

    init(gemini: GeminiClient,
         store: AtomStore,
         fetchEmbeddings: @escaping @MainActor () -> [(atomID: UUID, vector: [Float])]) {
        self.gemini = gemini
        self.store = store
        self.fetchEmbeddings = fetchEmbeddings
    }

    func submit() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { return }
        cancel()
        answer = ""
        citations = []
        stage = .embedding
        submitTime = Date()

        NousLogger.info("synthesis", "submit", ["q_len": q.count])

        task = Task { [weak self] in
            guard let self else { return }
            do {
                // 1. Embed the question. Use the asymmetric RETRIEVAL_QUERY task
                //    type — stored atoms are indexed as RETRIEVAL_DOCUMENT, so the
                //    query must use the matching query-side projection.
                let qVec = try await gemini.embed(q, taskType: .query)

                if Task.isCancelled { return }

                // 2. Cosine search against local atom-level embeddings.
                self.stage = .retrieving
                let allEmbs = self.fetchEmbeddings()
                let topAtoms = self.topK(query: qVec, embeddings: allEmbs, k: 12)

                // 2b. ALSO search per-passage meeting/long-note chunk vectors. A
                //     chunk hit pinpoints the passage ("what did we decide about
                //     pricing") rather than blurring across a whole meeting. We
                //     dedupe by parent atomID — an atom already retrieved at the
                //     atom level is not re-added; a chunk-only hit cites its parent.
                let chunkHits = self.topChunks(query: qVec, k: 8)
                let atomIDs = Set(topAtoms.map { $0.0 })
                let newChunkHits = chunkHits.filter { !atomIDs.contains($0.atomID) }

                // Citations: atom-level first, then de-duped chunk hits.
                var cites: [Citation] = topAtoms.compactMap { id, score -> Citation? in
                    guard let atom = self.store.atoms[id] else { return nil }
                    return Citation(id: id,
                                    snippet: String(atom.displayContent.prefix(200)),
                                    score: score)
                }
                var seenCiteAtoms = atomIDs
                for hit in newChunkHits where !seenCiteAtoms.contains(hit.atomID) {
                    seenCiteAtoms.insert(hit.atomID)
                    cites.append(Citation(id: hit.atomID,
                                          snippet: String(hit.text.prefix(200)),
                                          score: hit.score))
                }
                self.citations = cites

                // 3. Build context string. Atom-level snapshots first, then the
                //    matched passages from chunk-only hits (capped to bound prompt size).
                var blocks: [String] = topAtoms.compactMap { id, _ -> String? in
                    guard let atom = self.store.atoms[id] else { return nil }
                    return "[\(atom.type.label.uppercased())] \(atom.displayContent)"
                }
                for hit in newChunkHits.prefix(Self.maxChunkContextBlocks) {
                    let label = self.store.atoms[hit.atomID]?.type.label.uppercased() ?? "MEETING"
                    blocks.append("[\(label) — EXCERPT] \(hit.text)")
                }
                let context = blocks.joined(separator: "\n\n")

                // 4. Synthesize via Gemini
                self.stage = .synthesizing
                let result = try await gemini.synthesizeAnswer(question: q, context: context)

                if Task.isCancelled { return }
                self.answer = result
                self.stage = .done

                NousLogger.info("synthesis", "done", [
                    "citations": self.citations.count,
                    "answer_len": result.count,
                    "elapsed_ms": self.elapsedMs,
                ])
            } catch {
                guard !Task.isCancelled else { return }
                NousLogger.error("synthesis", "failed", [
                    "error": error.localizedDescription,
                    "elapsed_ms": self.elapsedMs,
                ])
                self.stage = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        let wasStreaming = isStreaming
        task?.cancel()
        task = nil
        if wasStreaming { stage = .idle }
    }

    func reset() {
        cancel()
        question = ""
        answer = ""
        citations = []
        stage = .idle
    }

    // MARK: - Chunk retrieval

    /// Number of chunk-only excerpts merged into the synthesis prompt. Caps prompt
    /// growth so a single noisy meeting can't crowd out everything else.
    private static let maxChunkContextBlocks = 6

    private struct ChunkHit {
        let atomID: UUID
        let text: String
        let score: Double
    }

    /// Cosine search across `MeetingChunkRecord` passage vectors. Reads from the
    /// shared SwiftData container directly (VM is `@MainActor`, so `mainContext` is
    /// safe). Failures degrade gracefully to an empty result — chunk retrieval is
    /// purely additive over the atom-level search.
    private func topChunks(query: [Float], k: Int) -> [ChunkHit] {
        guard !query.isEmpty else { return [] }
        let qNorm = Double(norm(query))
        guard qNorm > 0 else { return [] }

        let ctx = NousStore.shared.mainContext
        let desc = FetchDescriptor<MeetingChunkRecord>()
        let rows = (try? ctx.fetch(desc)) ?? []
        guard !rows.isEmpty else { return [] }

        return rows
            .compactMap { row -> ChunkHit? in
                let v = row.toFloatArray()
                guard v.count == query.count else { return nil }
                let dot = zip(query, v).map { Double($0) * Double($1) }.reduce(0, +)
                let vNorm = Double(norm(v))
                guard vNorm > 0 else { return nil }
                return ChunkHit(atomID: row.atomID, text: row.text,
                                score: dot / (qNorm * vNorm))
            }
            .filter { $0.score > 0.45 }
            .sorted { $0.score > $1.score }
            .prefix(k)
            .map { $0 }
    }

    // MARK: - Vector search

    private func topK(query: [Float],
                      embeddings: [(atomID: UUID, vector: [Float])],
                      k: Int) -> [(UUID, Double)] {
        guard !query.isEmpty else { return [] }
        let qNorm = norm(query)
        guard qNorm > 0 else { return [] }
        return embeddings
            .compactMap { entry -> (UUID, Double)? in
                let v = entry.vector
                guard v.count == query.count else { return nil }
                let dot = zip(query, v).map { Double($0) * Double($1) }.reduce(0, +)
                let vNorm = Double(norm(v))
                guard vNorm > 0 else { return nil }
                return (entry.atomID, dot / (Double(qNorm) * vNorm))
            }
            .filter { $0.1 > 0.45 }
            .sorted { $0.1 > $1.1 }
            .prefix(k)
            .map { ($0.0, $0.1) }
    }

    private func norm(_ v: [Float]) -> Float {
        v.reduce(0) { $0 + $1 * $1 }.squareRoot()
    }

    private var elapsedMs: Int {
        guard let t = submitTime else { return 0 }
        return Int(Date().timeIntervalSince(t) * 1000)
    }
}

private extension SynthesisVM.Stage {
    var isInteractive: Bool {
        switch self {
        case .idle, .done, .failed: true
        default: false
        }
    }
}
