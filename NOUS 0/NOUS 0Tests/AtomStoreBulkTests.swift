import Testing
import Foundation
@testable import NOUS_0

// Bulk operations fan a single user action across N selected atoms. Each reuses
// the corresponding single-atom path (dedupe/normalization/no-op semantics) and
// must leave the store consistent. Auto-refine is disabled so capture stays
// synchronous and network-free.
@MainActor
struct AtomStoreBulkTests {

    private func seed(_ store: AtomStore, _ texts: [String]) -> [UUID] {
        texts.compactMap { store.capture(raw: $0)?.id }
    }

    @Test("bulkAddTag adds a normalized tag to every atom")
    func bulkAddTagAddsAcrossAtoms() throws {
        AtomStoreTestSupport.disableAutoRefine()
        let store = try AtomStoreTestSupport.makeStore()
        let ids = seed(store, ["first note here", "second note here", "third note here"])
        #expect(ids.count == 3)

        // Mixed-case/whitespace tag — single addTag lowercases + trims.
        store.bulkAddTag(ids, tag: "  Roadmap  ")

        for id in ids {
            let tags = store.atoms[id]?.tags.map(\.value) ?? []
            #expect(tags.contains("roadmap"))
        }
    }

    @Test("bulkAddTag does not duplicate a tag already present")
    func bulkAddTagDedupes() throws {
        AtomStoreTestSupport.disableAutoRefine()
        let store = try AtomStoreTestSupport.makeStore()
        let ids = seed(store, ["alpha note text", "beta note text"])

        store.bulkAddTag(ids, tag: "shipping")
        store.bulkAddTag(ids, tag: "shipping")   // second pass — should no-op per atom

        for id in ids {
            let count = store.atoms[id]?.tags.filter { $0.value == "shipping" }.count
            #expect(count == 1)
        }
    }

    @Test("bulkSetType changes the type of every listed atom")
    func bulkSetTypeChangesTypes() throws {
        AtomStoreTestSupport.disableAutoRefine()
        let store = try AtomStoreTestSupport.makeStore()
        let ids = seed(store, ["needs doing one", "needs doing two", "needs doing three"])

        store.bulkSetType(ids, to: .task)

        for id in ids {
            #expect(store.atoms[id]?.type == .task)
        }
    }

    @Test("bulkDelete removes all listed atoms from ordered")
    func bulkDeleteRemovesAll() throws {
        AtomStoreTestSupport.disableAutoRefine()
        let store = try AtomStoreTestSupport.makeStore()
        let ids = seed(store, ["delete me one", "delete me two", "keep me around here"])
        let toDelete = Array(ids.prefix(2))
        let survivor = ids[2]

        store.bulkDelete(toDelete)

        for id in toDelete {
            #expect(!store.ordered.contains { $0.id == id })
            #expect(store.atoms[id]?.isDeleted == true)
        }
        // The unlisted atom is untouched.
        #expect(store.ordered.contains { $0.id == survivor })
    }
}
