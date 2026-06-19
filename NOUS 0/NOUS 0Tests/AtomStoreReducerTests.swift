import Testing
import Foundation
@testable import NOUS_0

// The reducer folds NoteEvents → AtomSnapshot. The correctness-critical pieces:
//   • B1 out-of-order guard (P0): a stale content event must NOT revert newer state.
//   • ordering: `ordered` is newest-first by createdAt.
//   • delete: soft-delete removes from `ordered`; `.deleted` is terminal.
//   • toggleTask / setType snapshot mutations and no-op semantics.
//
// We drive the reducer through `applyRemoteEvent` (persist=false path) using
// NoteEvents stamped with EXPLICIT timestamps via `NoteEvent(atomID:kind:payload:at:)`.
@MainActor
struct AtomStoreReducerTests {

    // MARK: - B1 out-of-order guard (the P0 fix)

    @Test("stale content event does NOT revert newer content")
    func staleContentEventIgnored() throws {
        // Arrange — a single atom, newest content applied first.
        let store = try AtomStoreTestSupport.makeStore()
        let id = UUID()
        let t0 = Date(timeIntervalSince1970: 1_000)
        let t1 = Date(timeIntervalSince1970: 2_000)

        // Seed the atom at t1 with the NEWER content.
        store.applyRemoteEvent(
            NoteEvent(atomID: id, kind: .created, payload: .init(content: "newer", type: .thought), at: t1)
        )
        #expect(store.atoms[id]?.rawContent == "newer")

        // Act — a STALER updatedRaw (t0 < t1) arrives out of order.
        store.applyRemoteEvent(
            NoteEvent(atomID: id, kind: .updatedRaw, payload: .init(content: "stale-older"), at: t0)
        )

        // Assert — newer content survives; the stale event was skipped.
        #expect(store.atoms[id]?.rawContent == "newer")
    }

    @Test("stale refined event does NOT revert newer content state")
    func staleRefinedEventIgnored() throws {
        let store = try AtomStoreTestSupport.makeStore()
        let id = UUID()
        let tOld = Date(timeIntervalSince1970: 5_000)
        let tNew = Date(timeIntervalSince1970: 9_000)

        // Apply the newer updatedRaw first.
        store.applyRemoteEvent(
            NoteEvent(atomID: id, kind: .updatedRaw, payload: .init(content: "current text"), at: tNew)
        )
        #expect(store.atoms[id]?.rawContent == "current text")

        // A staler refined (older than the content we already applied) must be skipped:
        // .refined shares the "content" guard group. If applied it would set
        // refinedContent = "stale refined". The guard must reject it.
        store.applyRemoteEvent(
            NoteEvent(atomID: id, kind: .refined, payload: .init(refinedContent: "stale refined"), at: tOld)
        )

        #expect(store.atoms[id]?.refinedContent == nil)
        #expect(store.atoms[id]?.rawContent == "current text")
    }

    @Test("newer remote content event DOES apply over older state")
    func newerRemoteEventApplies() throws {
        let store = try AtomStoreTestSupport.makeStore()
        let id = UUID()
        let tOld = Date(timeIntervalSince1970: 1_000)
        let tNew = Date(timeIntervalSince1970: 4_000)

        store.applyRemoteEvent(
            NoteEvent(atomID: id, kind: .created, payload: .init(content: "first", type: .thought), at: tOld)
        )
        // A genuinely newer updatedRaw should win.
        store.applyRemoteEvent(
            NoteEvent(atomID: id, kind: .updatedRaw, payload: .init(content: "second wins"), at: tNew)
        )

        #expect(store.atoms[id]?.rawContent == "second wins")
    }

    @Test("guard is per-group: a stale type event does not block a fresh content event")
    func guardIsPerGroup() throws {
        // type and content live in DIFFERENT guard groups, so an old type event
        // sets only the "type" timestamp and never blocks "content".
        let store = try AtomStoreTestSupport.makeStore()
        let id = UUID()
        let tOld = Date(timeIntervalSince1970: 1_000)
        let tNew = Date(timeIntervalSince1970: 2_000)

        store.applyRemoteEvent(
            NoteEvent(atomID: id, kind: .typeChanged, payload: .init(type: .task), at: tNew)
        )
        // Older content event — different group, so it still applies (first content event).
        store.applyRemoteEvent(
            NoteEvent(atomID: id, kind: .created, payload: .init(content: "body", type: .thought), at: tOld)
        )

        // .created sets type=.thought (its payload), but it's the first "content"
        // event so it applies. Surprising-but-correct: created overwrites the type
        // because its fold unconditionally sets `a.type = payload.type ?? .thought`.
        #expect(store.atoms[id]?.rawContent == "body")
    }

    // MARK: - Ordering

    @Test("ordered is newest-first by createdAt")
    func orderedNewestFirst() throws {
        let store = try AtomStoreTestSupport.makeStore()
        let old = UUID(), mid = UUID(), new = UUID()

        store.applyRemoteEvent(NoteEvent(atomID: old, kind: .created,
            payload: .init(content: "oldest", type: .thought), at: Date(timeIntervalSince1970: 100)))
        store.applyRemoteEvent(NoteEvent(atomID: new, kind: .created,
            payload: .init(content: "newest", type: .thought), at: Date(timeIntervalSince1970: 300)))
        store.applyRemoteEvent(NoteEvent(atomID: mid, kind: .created,
            payload: .init(content: "middle", type: .thought), at: Date(timeIntervalSince1970: 200)))

        #expect(store.ordered.map(\.id) == [new, mid, old])
    }

    // MARK: - Delete (soft, terminal)

    @Test("delete removes the atom from ordered (soft-delete)")
    func deleteRemovesFromOrdered() throws {
        AtomStoreTestSupport.disableAutoRefine()
        let store = try AtomStoreTestSupport.makeStore()

        let snap = try #require(store.capture(raw: "to be deleted soon"))
        #expect(store.ordered.contains { $0.id == snap.id })

        store.delete(id: snap.id)

        #expect(!store.ordered.contains { $0.id == snap.id })
        // Soft-delete: the atom record is still present, flagged deleted.
        #expect(store.atoms[snap.id]?.isDeleted == true)
    }

    @Test("deleted is terminal: a later non-deleted event does not resurrect into ordered")
    func deletedIsTerminal() throws {
        let store = try AtomStoreTestSupport.makeStore()
        let id = UUID()

        store.applyRemoteEvent(NoteEvent(atomID: id, kind: .created,
            payload: .init(content: "alive", type: .thought), at: Date(timeIntervalSince1970: 100)))
        store.applyRemoteEvent(NoteEvent(atomID: id, kind: .deleted,
            payload: .init(), at: Date(timeIntervalSince1970: 200)))
        #expect(store.atoms[id]?.isDeleted == true)
        #expect(!store.ordered.contains { $0.id == id })

        // A LATER content edit arrives (clock-forward). `.deleted` bypasses the B1
        // guard (monotonic/terminal) but does NOT itself prevent a later edit from
        // folding. The reducer DOES mutate rawContent — but isDeleted stays true and
        // rebuildOrdered() filters it out, so it never reappears in `ordered`.
        store.applyRemoteEvent(NoteEvent(atomID: id, kind: .updatedRaw,
            payload: .init(content: "tried to resurrect"), at: Date(timeIntervalSince1970: 300)))

        // Verified against the reducer's ACTUAL behavior: isDeleted is sticky,
        // ordered excludes it. (Note: rawContent did change — the fold has no
        // "ignore edits after delete" branch — but the atom remains invisible.)
        #expect(store.atoms[id]?.isDeleted == true)
        #expect(!store.ordered.contains { $0.id == id })
    }

    // MARK: - toggleTask / setType

    @Test("toggleTask flips taskDone and coerces type to task")
    func toggleTaskMutatesSnapshot() throws {
        AtomStoreTestSupport.disableAutoRefine()
        let store = try AtomStoreTestSupport.makeStore()

        let snap = try #require(store.capture(raw: "remember to do this"))
        #expect(store.atoms[snap.id]?.taskDone == nil)

        store.toggleTask(id: snap.id)
        #expect(store.atoms[snap.id]?.taskDone == true)
        #expect(store.atoms[snap.id]?.type == .task)   // toggle forces .task

        store.toggleTask(id: snap.id)
        #expect(store.atoms[snap.id]?.taskDone == false)
    }

    @Test("setType changes the snapshot type")
    func setTypeChangesType() throws {
        AtomStoreTestSupport.disableAutoRefine()
        let store = try AtomStoreTestSupport.makeStore()

        let snap = try #require(store.capture(raw: "a decision was made"))
        #expect(store.atoms[snap.id]?.type == .thought)

        store.setType(id: snap.id, to: .decision)
        #expect(store.atoms[snap.id]?.type == .decision)
    }

    @Test("setType to the same type is a no-op (no new event)")
    func setTypeSameIsNoOp() throws {
        AtomStoreTestSupport.disableAutoRefine()
        let store = try AtomStoreTestSupport.makeStore()

        let snap = try #require(store.capture(raw: "still just a thought"))
        let before = store.atoms[snap.id]

        store.setType(id: snap.id, to: .thought)   // same type — guarded out

        #expect(store.atoms[snap.id]?.type == .thought)
        // updatedAt unchanged confirms no event was folded.
        #expect(store.atoms[snap.id]?.updatedAt == before?.updatedAt)
    }
}
