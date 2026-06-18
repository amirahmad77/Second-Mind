import Foundation
import SwiftData
import Accelerate

/// Shared "related atoms" finder for the iOS and macOS root views.
///
/// Previously both `RootView` and `MacRootView` carried verbatim copies of the
/// semantic + lexical related logic. The semantic path fetched every
/// `EmbeddingRecord`, decoded each vector, and ran cosine similarity over all of
/// them **synchronously on the MainActor** inside the view body — re-running on
/// every detail-view open.
///
/// `RelatedFinder` deduplicates that logic and pushes the O(n·dim) math off the
/// MainActor: the main actor only fetches records and builds plain Sendable
/// arrays (`[Float]`, `UUID`), then a `Task.detached` does the cosine work and
/// returns `[UUID]`. The main actor maps the IDs back to `AtomSnapshot`s.
enum RelatedFinder {

    /// Minimum cosine similarity for a semantic match.
    private static let semanticThreshold: Float = 0.55
    /// Max related atoms surfaced.
    private static let maxResults = 4

    // MARK: - Semantic (off-main compute) + lexical fallback

    /// Finds atoms related to `id`.
    ///
    /// Fetches embeddings and snapshots the data needed for compute on the main
    /// actor (source `[Float]` + `[(UUID, [Float])]` for all other live atoms),
    /// then runs cosine similarity in a detached task. Only `Sendable` value
    /// types (`[Float]`, `UUID`) cross the actor boundary — `EmbeddingRecord`
    /// (a SwiftData `@Model`) and `AtomStore` never leave the main actor.
    ///
    /// Falls back to `lexicalRelated` when there is no source vector or no
    /// semantic hits.
    @MainActor
    static func related(for id: UUID, store: AtomStore, context: ModelContext) async -> [AtomSnapshot] {
        let descriptor = FetchDescriptor<EmbeddingRecord>()
        let allRecords = (try? context.fetch(descriptor)) ?? []

        guard let sourceRecord = allRecords.first(where: { $0.atomID == id }) else {
            return lexicalRelated(for: id, store: store)
        }
        let sourceVec = sourceRecord.toFloatArray()
        guard !sourceVec.isEmpty else {
            return lexicalRelated(for: id, store: store)
        }

        // Build a Sendable snapshot of the candidate vectors on the main actor.
        // Only non-deleted atoms currently present in the store are eligible.
        let candidates: [(UUID, [Float])] = allRecords.compactMap { record in
            guard record.atomID != id,
                  let atom = store.atoms[record.atomID],
                  !atom.isDeleted else { return nil }
            return (record.atomID, record.toFloatArray())
        }

        // Off-main cosine compute. `sourceVec` ([Float]) and `candidates`
        // ([(UUID, [Float])]) are all Sendable value types.
        let matchedIDs: [UUID] = await Task.detached(priority: .userInitiated) {
            candidates
                .compactMap { candidate -> (UUID, Float)? in
                    let (uuid, vec) = candidate
                    guard vec.count == sourceVec.count else { return nil }
                    let sim = cosineSimilarity(sourceVec, vec)
                    return sim >= semanticThreshold ? (uuid, sim) : nil
                }
                .sorted { $0.1 > $1.1 }
                .prefix(maxResults)
                .map(\.0)
        }.value

        // Back on the main actor: map IDs → snapshots, filtering deleted.
        let snapshots = matchedIDs.compactMap { uuid -> AtomSnapshot? in
            guard let atom = store.atoms[uuid], !atom.isDeleted else { return nil }
            return atom
        }

        return snapshots.isEmpty ? lexicalRelated(for: id, store: store) : snapshots
    }

    // MARK: - Lexical fallback

    /// Heuristic related atoms based on type, shared tags, word overlap, and
    /// recency. Used when no embeddings exist or the semantic pass finds nothing.
    @MainActor
    static func lexicalRelated(for id: UUID, store: AtomStore) -> [AtomSnapshot] {
        guard let a = store.atoms[id] else { return [] }
        let candidates = store.ordered.filter { $0.id != id && !$0.isDeleted }
        let wordsA = Set(a.displayContent.lowercased().split(separator: " ").map(String.init))
        let tagsA = Set(a.tags.map(\.value))
        let scored = candidates.map { c -> (AtomSnapshot, Double) in
            var score = 0.0
            if c.type == a.type { score += 0.3 }
            score += Double(tagsA.intersection(Set(c.tags.map(\.value))).count) * 0.4
            let wordsB = Set(c.displayContent.lowercased().split(separator: " ").map(String.init))
            score += Double(wordsA.intersection(wordsB).count) * 0.05
            let dt = abs(a.createdAt.timeIntervalSince(c.createdAt))
            score += max(0, 1.0 - dt / (60 * 60 * 24 * 30)) * 0.1
            return (c, score)
        }
        return scored.filter { $0.1 >= 0.5 }.sorted { $0.1 > $1.1 }.prefix(maxResults).map(\.0)
    }

    // MARK: - Math

    /// Cosine similarity via Accelerate `vDSP`. `nonisolated` so it can run
    /// inside the detached compute task. Returns 0 when either vector is zero.
    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        var dot: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        var normA: Float = 0; vDSP_svesq(a, 1, &normA, vDSP_Length(a.count))
        var normB: Float = 0; vDSP_svesq(b, 1, &normB, vDSP_Length(b.count))
        let denom = sqrtf(normA) * sqrtf(normB)
        return denom == 0 ? 0 : dot / denom
    }
}
