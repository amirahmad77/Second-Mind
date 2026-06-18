import Testing
import Foundation
@testable import NOUS_0

// cosineSimilarity backs semantic "related atoms". It must be 1 for identical
// direction, 0 for orthogonal, and safely 0 (not NaN) for zero-magnitude input.
struct RelatedFinderTests {

    @Test("identical vectors → ~1.0")
    func identical() {
        let v: [Float] = [0.2, 0.5, 0.9, 0.1]
        #expect(abs(RelatedFinder.cosineSimilarity(v, v) - 1.0) < 1e-4)
    }

    @Test("orthogonal vectors → ~0.0")
    func orthogonal() {
        #expect(abs(RelatedFinder.cosineSimilarity([1, 0, 0], [0, 1, 0])) < 1e-4)
    }

    @Test("opposite vectors → ~-1.0")
    func opposite() {
        #expect(abs(RelatedFinder.cosineSimilarity([1, 0], [-1, 0]) - (-1.0)) < 1e-4)
    }

    @Test("zero-magnitude vector → 0, never NaN")
    func zeroVector() {
        let s = RelatedFinder.cosineSimilarity([0, 0, 0], [1, 2, 3])
        #expect(s == 0)
        #expect(!s.isNaN)
    }
}
