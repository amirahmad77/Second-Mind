import Testing
import Foundation
@testable import NOUS_0

// NoteEventRecord is the SwiftData ledger row. `toEvent()` must be tolerant:
// an UNKNOWN kindRaw (e.g. a newer client/extension shipping a kind iOS doesn't
// model yet) returns nil instead of crashing, so the pull path can skip it; a
// known kind round-trips with its payload intact.
@MainActor
struct NoteEventTests {

    private func record(kindRaw: String, payload: NoteEventPayload) -> NoteEventRecord {
        let data = (try? JSONEncoder.nous.encode(payload)) ?? Data()
        return NoteEventRecord(
            id: UUID(), atomID: UUID(), kindRaw: kindRaw,
            payloadJSON: data, createdAt: Date(timeIntervalSince1970: 1_000),
            userID: UUID()
        )
    }

    @Test("toEvent returns nil for an unknown kindRaw (no crash)")
    func unknownKindDecodesToNil() {
        let rec = record(kindRaw: "someFutureKind", payload: .init(content: "x"))
        #expect(rec.toEvent() == nil)
    }

    @Test("toEvent round-trips a known kind with its payload")
    func knownKindRoundTrips() throws {
        let rec = record(kindRaw: NoteEventKind.created.rawValue,
                         payload: .init(content: "hello world", type: .task))
        let event = try #require(rec.toEvent())

        #expect(event.kind == .created)
        #expect(event.payload.content == "hello world")
        #expect(event.payload.type == .task)
        #expect(event.atomID == rec.atomID)
        #expect(event.id == rec.id)
        #expect(event.createdAt == rec.createdAt)
    }

    @Test("NoteEventRecord.from then toEvent preserves the event identity")
    func recordRoundTrip() throws {
        let original = NoteEvent(atomID: UUID(), kind: .tagged,
                                 payload: .init(tags: ["roadmap", "v3"]),
                                 at: Date(timeIntervalSince1970: 2_000))
        let rec = NoteEventRecord.from(original)
        let decoded = try #require(rec.toEvent())

        #expect(decoded.id == original.id)
        #expect(decoded.atomID == original.atomID)
        #expect(decoded.kind == .tagged)
        #expect(decoded.payload.tags == ["roadmap", "v3"])
    }

    @Test("payload tolerant decode maps unknown extension type to reference")
    func tolerantTypeMapping() throws {
        // The Chrome extension may emit "type": "web". The custom decoder maps
        // web/link/article → .reference rather than throwing.
        let json = #"{"content":"a captured page","type":"web"}"#.data(using: .utf8)!
        let payload = try JSONDecoder.nous.decode(NoteEventPayload.self, from: json)

        #expect(payload.type == .reference)
        #expect(payload.content == "a captured page")
    }

    @Test("payload tolerant decode drops a fully-unknown type to nil")
    func tolerantTypeUnknownToNil() throws {
        let json = #"{"content":"weird","type":"quantum"}"#.data(using: .utf8)!
        let payload = try JSONDecoder.nous.decode(NoteEventPayload.self, from: json)

        #expect(payload.type == nil)
        #expect(payload.content == "weird")
    }
}
