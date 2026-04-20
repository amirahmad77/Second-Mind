import Foundation
import SwiftData

/// SwiftData ledger row. Append-only, payload encoded as JSON for schema stability.
@Model
final class NoteEventRecord {
    #Index<NoteEventRecord>([\.synced, \.createdAt], [\.atomID, \.createdAt])
    @Attribute(.unique) var id: UUID
    var atomID: UUID
    var kindRaw: String
    var payloadJSON: Data
    var createdAt: Date
    var userID: UUID
    var synced: Bool

    init(id: UUID, atomID: UUID, kindRaw: String, payloadJSON: Data, createdAt: Date, userID: UUID, synced: Bool = false) {
        self.id = id; self.atomID = atomID; self.kindRaw = kindRaw
        self.payloadJSON = payloadJSON; self.createdAt = createdAt
        self.userID = userID; self.synced = synced
    }

    static func from(_ e: NoteEvent) -> NoteEventRecord {
        let data = (try? JSONEncoder.nous.encode(e.payload)) ?? Data()
        return .init(id: e.id, atomID: e.atomID, kindRaw: e.kind.rawValue,
                     payloadJSON: data, createdAt: e.createdAt, userID: e.userID)
    }

    func toEvent() -> NoteEvent? {
        guard let kind = NoteEventKind(rawValue: kindRaw) else { return nil }
        let payload = (try? JSONDecoder.nous.decode(NoteEventPayload.self, from: payloadJSON)) ?? .init()
        return NoteEvent(
            id: id, atomID: atomID, kind: kind, payload: payload,
            createdAt: createdAt, userID: userID
        )
    }
}

extension NoteEvent {
    init(id: UUID, atomID: UUID, kind: NoteEventKind, payload: NoteEventPayload, createdAt: Date, userID: UUID) {
        self.id = id; self.atomID = atomID; self.kind = kind
        self.payload = payload; self.createdAt = createdAt; self.userID = userID
    }
}

extension JSONEncoder {
    static let nous: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}
extension JSONDecoder {
    static let nous: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

/// Optional cache of embedding vectors. Bytes = Float32 little-endian packed.
@Model
final class EmbeddingRecord {
    @Attribute(.unique) var atomID: UUID
    var dim: Int
    var vector: Data
    var updatedAt: Date
    init(atomID: UUID, dim: Int, vector: Data, updatedAt: Date = .now) {
        self.atomID = atomID; self.dim = dim; self.vector = vector; self.updatedAt = updatedAt
    }
}
