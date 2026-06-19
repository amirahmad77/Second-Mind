import Foundation
import SwiftData
@testable import NOUS_0

/// Shared fixtures for AtomStore tests.
///
/// Every test gets a FRESH store backed by an in-memory SwiftData container, so
/// tests touch no disk, share no state, and (critically) hit no network.
///
/// ⚠️ Network avoidance: `AtomStore.capture` / `updateRaw` call `startRefine`,
/// which fires a Gemini network Task when auto-refine is on AND raw.count >= 8.
/// `disableAutoRefine()` writes the `nous.settings.autoRefine` UserDefaults key
/// to `false` so those paths clear the shimmer synchronously instead. Call it at
/// the top of any test that captures/edits content.
enum AtomStoreTestSupport {

    /// Builds a store on an isolated in-memory container. Mirrors the production
    /// schema. No sync bootstrap is started (we never call `sync.bootstrap()`),
    /// so the periodic drain/pull loop never runs.
    @MainActor
    static func makeStore() throws -> AtomStore {
        let schema = Schema([NoteEventRecord.self, EmbeddingRecord.self, MeetingChunkRecord.self])
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        )
        let ctx = ModelContext(container)
        let gemini = GeminiClient()
        let sync = SyncDaemon(context: ctx, supabase: SupabaseClient(), gemini: gemini)
        return AtomStore(context: ctx, sync: sync, gemini: gemini, backend: nil)
    }

    /// Turn OFF auto-refine so `capture`/`updateRaw` never spawn a Gemini Task.
    /// Returns the prior value's restorer is unnecessary for test isolation since
    /// the key is global, but each test that mutates content should call this.
    static func disableAutoRefine() {
        UserDefaults.standard.set(false, forKey: "nous.settings.autoRefine")
    }
}
