import Foundation
import SwiftData

/// Shared persistence location. The app, the widget extension, and App Intents
/// all open ONE SwiftData store in the App Group container so they see the same
/// atoms. Falls back to the default per-app container if the group container is
/// unavailable (e.g. the App Group entitlement isn't provisioned in a build),
/// so the app never fails to launch.
enum NousStore {
    static let appGroupID = "group.com.nous-core.NOUS-0"

    static let shared: ModelContainer = {
        let schema = Schema([NoteEventRecord.self, EmbeddingRecord.self])
        do {
            let config = ModelConfiguration(schema: schema,
                                            groupContainer: .identifier(appGroupID))
            return try ModelContainer(for: schema, configurations: config)
        } catch {
            NousLogger.error("store", "app-group container unavailable; using default",
                             ["error": error.localizedDescription])
            // Last resort — a per-app container so the app still runs.
            return try! ModelContainer(for: schema)
        }
    }()
}

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
    nonisolated(unsafe) static let nous: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}
extension JSONDecoder {
    nonisolated(unsafe) static let nous: JSONDecoder = {
        let d = JSONDecoder()
        // Supabase + backend emit ISO8601 with microsecond precision
        // (2026-04-21T17:35:14.123456Z). Default `.iso8601` rejects fractional
        // seconds. Custom strategy tries fractional first, falls back to plain.
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        d.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            if let d = withFrac.date(from: s) { return d }
            if let d = plain.date(from: s) { return d }
            throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(),
                debugDescription: "unrecognized ISO8601: \(s)")
        }
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

    func toFloatArray() -> [Float] {
        vector.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}
