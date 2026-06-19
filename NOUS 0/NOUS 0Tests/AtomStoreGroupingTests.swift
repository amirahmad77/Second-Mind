import Testing
import Foundation
@testable import NOUS_0

// groupedByDay buckets `ordered` atoms by calendar day (newest day first) and
// memoizes the result keyed by (filter, tag, version). A mutation bumps `version`
// and invalidates the cache. These tests drive atoms in via applyRemoteEvent with
// explicit timestamps so day bucketing is deterministic.
@MainActor
struct AtomStoreGroupingTests {

    private func createEvent(_ id: UUID, _ content: String, at date: Date) -> NoteEvent {
        NoteEvent(atomID: id, kind: .created,
                  payload: .init(content: content, type: .thought), at: date)
    }

    // Tags are applied by `.tagged` events, not `.created` (the reducer ignores
    // tags on a created payload) — mirror the real event flow in tests.
    private func tagEvent(_ id: UUID, _ tags: [String], at date: Date) -> NoteEvent {
        NoteEvent(atomID: id, kind: .tagged, payload: .init(tags: tags), at: date)
    }

    @Test("groupedByDay buckets atoms onto distinct calendar days")
    func bucketsByDay() throws {
        let store = try AtomStoreTestSupport.makeStore()
        let cal = Calendar.current
        let dayA = cal.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        let dayB = cal.date(byAdding: .day, value: -2, to: dayA)!

        // Two atoms on dayA, one on dayB.
        store.applyRemoteEvent(createEvent(UUID(), "a1 morning note", at: dayA.addingTimeInterval(3_600)))
        store.applyRemoteEvent(createEvent(UUID(), "a2 evening note", at: dayA.addingTimeInterval(40_000)))
        store.applyRemoteEvent(createEvent(UUID(), "b1 earlier note", at: dayB.addingTimeInterval(7_200)))

        let groups = store.groupedByDay()

        #expect(groups.count == 2)
        // Newest day first.
        #expect(groups.first?.day == dayA)
        #expect(groups.first?.atoms.count == 2)
        #expect(groups.last?.day == dayB)
        #expect(groups.last?.atoms.count == 1)
    }

    @Test("groupedByDay filters by text query")
    func filtersByText() throws {
        let store = try AtomStoreTestSupport.makeStore()
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        store.applyRemoteEvent(createEvent(UUID(), "supabase migration plan", at: base))
        store.applyRemoteEvent(createEvent(UUID(), "groceries for the weekend", at: base.addingTimeInterval(10)))

        let groups = store.groupedByDay(filter: "supabase")
        let allAtoms = groups.flatMap(\.atoms)

        #expect(allAtoms.count == 1)
        #expect(allAtoms.first?.rawContent == "supabase migration plan")
    }

    @Test("groupedByDay filters by tag")
    func filtersByTag() throws {
        let store = try AtomStoreTestSupport.makeStore()
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        let taggedID = UUID()
        store.applyRemoteEvent(createEvent(taggedID, "tagged note one", at: base))
        store.applyRemoteEvent(tagEvent(taggedID, ["roadmap"], at: base.addingTimeInterval(1)))
        store.applyRemoteEvent(createEvent(UUID(), "untagged note two", at: base.addingTimeInterval(10)))

        let groups = store.groupedByDay(tag: "roadmap")
        let allAtoms = groups.flatMap(\.atoms)

        #expect(allAtoms.count == 1)
        #expect(allAtoms.first?.tags.contains { $0.value == "roadmap" } == true)
    }

    @Test("groupedByDay memoizes: same (filter,tag,version) returns equal grouping")
    func memoizationReturnsSameValue() throws {
        let store = try AtomStoreTestSupport.makeStore()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        store.applyRemoteEvent(createEvent(UUID(), "first cached note", at: base))
        store.applyRemoteEvent(createEvent(UUID(), "second cached note", at: base.addingTimeInterval(10)))

        // Two reads with no intervening mutation should be identical (cache hit).
        let first = store.groupedByDay()
        let second = store.groupedByDay()

        #expect(first.map(\.day) == second.map(\.day))
        #expect(first.flatMap { $0.atoms.map(\.id) } == second.flatMap { $0.atoms.map(\.id) })
    }

    @Test("groupedByDay cache invalidates after a mutation bumps version")
    func cacheInvalidatesOnMutation() throws {
        AtomStoreTestSupport.disableAutoRefine()
        let store = try AtomStoreTestSupport.makeStore()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        store.applyRemoteEvent(createEvent(UUID(), "only note so far", at: base))

        let before = store.groupedByDay()
        let beforeCount = before.flatMap(\.atoms).count
        #expect(beforeCount == 1)

        // A fresh capture bumps `version` → next groupedByDay must recompute.
        _ = store.capture(raw: "a brand new captured note")

        let after = store.groupedByDay()
        let afterCount = after.flatMap(\.atoms).count
        #expect(afterCount == 2)
    }
}
