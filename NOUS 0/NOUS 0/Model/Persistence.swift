import Foundation
import SwiftData

/// Shared persistence location. The app, the widget extension, and App Intents
/// all open ONE SwiftData store in the App Group container so they see the same
/// atoms. Falls back to the default per-app container if the group container is
/// unavailable (e.g. the App Group entitlement isn't provisioned in a build),
/// so the app never fails to launch.
enum NousStore {
    static let appGroupID = "group.com.nous-core.NOUS-0"

    /// One-time migration guard. When the store moved from the default per-app
    /// location into the App Group container, existing on-device events lived in
    /// the OLD store and would appear "lost" until a remote pull re-synced them.
    /// This flag gates a one-shot import of the legacy store's rows into the new
    /// App-Group container so nothing is lost on the move.
    private static let legacyImportFlagKey = "nous.migrated.appGroupStore.v1"

    static let shared: ModelContainer = {
        let schema = Schema([NoteEventRecord.self, EmbeddingRecord.self, MeetingChunkRecord.self])
        do {
            let config = ModelConfiguration(schema: schema,
                                            groupContainer: .identifier(appGroupID))
            let container = try ModelContainer(for: schema, configurations: config)
            // MIGRATION 1 — import legacy default-location store into the App Group
            // container. Defensive: never throws out of the initializer, never blocks
            // launch beyond a single synchronous fetch/insert pass guarded by a flag.
            migrateLegacyStoreIfNeeded(into: container, schema: schema)
            return container
        } catch {
            NousLogger.error("store", "app-group container unavailable; using default",
                             ["error": error.localizedDescription])
            // Last resort — a per-app container so the app still runs.
            return try! ModelContainer(for: schema)
        }
    }()

    /// MIGRATION 1 — copies all `NoteEventRecord` + `EmbeddingRecord` rows from the
    /// legacy default-location SwiftData store into the App-Group `target` container,
    /// exactly once. Runs only when the App-Group store is empty (zero
    /// `NoteEventRecord`s) — i.e. a fresh App-Group store that may be shadowing an
    /// existing legacy store from before the move.
    ///
    /// Fully defensive: any failure (legacy store unopenable, fetch/insert error) is
    /// logged and swallowed, the flag is still set, and `shared` keeps returning the
    /// App-Group container regardless. Never crashes launch.
    private static func migrateLegacyStoreIfNeeded(into target: ModelContainer, schema: Schema) {
        let defaults = UserDefaults(suiteName: appGroupID) ?? .standard
        guard !defaults.bool(forKey: legacyImportFlagKey) else { return }

        do {
            let targetContext = ModelContext(target)
            // Only import into an empty App-Group store. If it already has events,
            // the move already happened (or this is a genuinely new install) — skip.
            let existing = try targetContext.fetchCount(FetchDescriptor<NoteEventRecord>())
            guard existing == 0 else {
                defaults.set(true, forKey: legacyImportFlagKey)
                NousLogger.info("store", "legacy import skipped — app-group store not empty",
                                ["existing": "\(existing)"])
                return
            }

            // Open the legacy store at the DEFAULT location (no groupContainer). This
            // is a second live container over a different SQLite file — safe because it
            // is a distinct configuration with no overlapping URL.
            let legacyConfig = ModelConfiguration(schema: schema)
            let legacyContainer = try ModelContainer(for: schema, configurations: legacyConfig)
            let legacyContext = ModelContext(legacyContainer)

            let legacyEvents = (try? legacyContext.fetch(
                FetchDescriptor<NoteEventRecord>())) ?? []
            let legacyEmbeds = (try? legacyContext.fetch(
                FetchDescriptor<EmbeddingRecord>())) ?? []

            // Nothing in the legacy store — likely a clean first install, not a move.
            if legacyEvents.isEmpty && legacyEmbeds.isEmpty {
                defaults.set(true, forKey: legacyImportFlagKey)
                NousLogger.info("store", "legacy import skipped — legacy store empty")
                return
            }

            // Dedupe defensively even though the target is empty (belt-and-braces).
            var seenEventIDs = Set<UUID>()
            var importedEvents = 0
            for row in legacyEvents where seenEventIDs.insert(row.id).inserted {
                let copy = NoteEventRecord(
                    id: row.id, atomID: row.atomID, kindRaw: row.kindRaw,
                    payloadJSON: row.payloadJSON, createdAt: row.createdAt,
                    userID: row.userID, synced: row.synced)
                targetContext.insert(copy)
                importedEvents += 1
            }

            var seenEmbedIDs = Set<UUID>()
            var importedEmbeds = 0
            for row in legacyEmbeds where seenEmbedIDs.insert(row.atomID).inserted {
                let copy = EmbeddingRecord(
                    atomID: row.atomID, dim: row.dim,
                    vector: row.vector, updatedAt: row.updatedAt)
                targetContext.insert(copy)
                importedEmbeds += 1
            }

            try targetContext.save()
            defaults.set(true, forKey: legacyImportFlagKey)
            NousLogger.info("store", "legacy store imported into app-group container",
                            ["events": "\(importedEvents)", "embeddings": "\(importedEmbeds)"])
        } catch {
            // Legacy store couldn't be opened / migration failed: set the flag so we
            // never retry on every launch, and continue with the App-Group container.
            defaults.set(true, forKey: legacyImportFlagKey)
            NousLogger.warning("store", "legacy store import failed; continuing",
                               ["error": error.localizedDescription])
        }
    }
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

/// Per-passage embedding for long atoms (meetings, long notes). One atom fans out
/// to N chunk vectors so "ask your meetings" retrieves the relevant passage rather
/// than a single blurry whole-meeting vector. Bytes = Float32 little-endian packed,
/// same layout as `EmbeddingRecord`. A chunk hit cites its parent atom (`atomID`).
@Model
final class MeetingChunkRecord {
    #Index<MeetingChunkRecord>([\.atomID, \.chunkIndex])
    @Attribute(.unique) var id: UUID
    var atomID: UUID
    var chunkIndex: Int
    var text: String
    var dim: Int
    var vector: Data
    var updatedAt: Date

    init(id: UUID = UUID(), atomID: UUID, chunkIndex: Int, text: String,
         dim: Int, vector: Data, updatedAt: Date = .now) {
        self.id = id; self.atomID = atomID; self.chunkIndex = chunkIndex
        self.text = text; self.dim = dim; self.vector = vector; self.updatedAt = updatedAt
    }

    func toFloatArray() -> [Float] {
        vector.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}
