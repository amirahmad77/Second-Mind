import Testing
import Foundation
@testable import NOUS_0

// capture() is the front door of the event ledger. These pin its contract:
// a valid capture produces an atom visible in `atoms`/`ordered` carrying the
// normalized raw content; empty/whitespace input is rejected (returns nil).
//
// Auto-refine is disabled so capture never spawns a Gemini network task.
@MainActor
struct AtomStoreCaptureTests {

    @Test("capture creates an atom present in atoms and ordered with raw content")
    func captureCreatesAtom() throws {
        // Arrange
        AtomStoreTestSupport.disableAutoRefine()
        let store = try AtomStoreTestSupport.makeStore()

        // Act
        let snap = store.capture(raw: "ship the v3 release")

        // Assert
        let id = try #require(snap?.id)
        #expect(store.atoms[id] != nil)
        #expect(store.atoms[id]?.rawContent == "ship the v3 release")
        #expect(store.ordered.contains { $0.id == id })
        #expect(store.ordered.first(where: { $0.id == id })?.rawContent == "ship the v3 release")
    }

    @Test("capture trims surrounding whitespace from raw content")
    func captureNormalizesWhitespace() throws {
        AtomStoreTestSupport.disableAutoRefine()
        let store = try AtomStoreTestSupport.makeStore()

        let snap = store.capture(raw: "   trimmed thought   ")

        #expect(snap?.rawContent == "trimmed thought")
    }

    @Test("capture of empty string returns nil and creates no atom")
    func captureEmptyReturnsNil() throws {
        AtomStoreTestSupport.disableAutoRefine()
        let store = try AtomStoreTestSupport.makeStore()

        let snap = store.capture(raw: "")

        #expect(snap == nil)
        #expect(store.atoms.isEmpty)
        #expect(store.ordered.isEmpty)
    }

    @Test("capture of whitespace-only string returns nil")
    func captureWhitespaceReturnsNil() throws {
        AtomStoreTestSupport.disableAutoRefine()
        let store = try AtomStoreTestSupport.makeStore()

        let snap = store.capture(raw: "   \n\t  ")

        #expect(snap == nil)
        #expect(store.ordered.isEmpty)
    }

    @Test("default capture type is thought")
    func captureDefaultType() throws {
        AtomStoreTestSupport.disableAutoRefine()
        let store = try AtomStoreTestSupport.makeStore()

        let snap = store.capture(raw: "a plain note here")

        #expect(snap?.type == .thought)
    }
}
