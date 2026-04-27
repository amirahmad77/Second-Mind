import Foundation
import CoreSpotlight
import UniformTypeIdentifiers

/// Donates atoms to iOS Spotlight so the system-wide search surface (swipe-down
/// from home, search field anywhere) finds the user's notes. Tap a result =
/// `NSUserActivity` with `nous://atom/<uuid>` deep link, handled in NOUS_0App.
///
/// Strategy:
///   - Index the entire vault on first call after launch (debounced 1.2s after
///     bootstrap so we don't compete w/ event replay).
///   - Index single atom on capture / refine (cheap incremental update).
///   - Delete from index on soft-delete.
///
/// Cost: CSSearchableIndex is on-device, no network. Per-atom payload <2KB.
/// Apple recommends batching, which we do via `indexSearchableItems(_:)` taking
/// an array; a 1000-atom vault indexes in well under a second on modern devices.
@MainActor
final class SpotlightIndexer {

    static let shared = SpotlightIndexer()
    private init() {}

    private let domain = "atom"
    private let index = CSSearchableIndex.default()

    private var bootstrapTask: Task<Void, Never>?

    // MARK: - Bulk

    /// Re-index the entire live vault. Idempotent: re-running just refreshes
    /// existing items in place. Safe to call multiple times.
    func indexAll(_ atoms: [AtomSnapshot]) {
        bootstrapTask?.cancel()
        bootstrapTask = Task { [weak self] in
            guard let self else { return }
            // Debounce: let the app finish bootstrap before competing for IO.
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if Task.isCancelled { return }

            let live = atoms.filter { !$0.isDeleted }
            let items = live.map { Self.makeItem(for: $0) }
            do {
                try await self.index.indexSearchableItems(items)
            } catch {
                // Spotlight failures are non-fatal — silent.
            }
        }
    }

    // MARK: - Incremental

    /// Index or refresh a single atom. Call after capture, refine, tag changes.
    func upsert(_ atom: AtomSnapshot) {
        guard !atom.isDeleted else { delete(id: atom.id); return }
        let item = Self.makeItem(for: atom)
        index.indexSearchableItems([item]) { _ in /* silent */ }
    }

    /// Remove an atom from the system index.
    func delete(id: UUID) {
        index.deleteSearchableItems(withIdentifiers: [id.uuidString]) { _ in }
    }

    /// Drop everything we've donated. Useful for "local-only mode" or vault wipe.
    func deleteAll() {
        index.deleteSearchableItems(withDomainIdentifiers: [domain]) { _ in }
    }

    // MARK: - Item construction

    private static func makeItem(for atom: AtomSnapshot) -> CSSearchableItem {
        let attrs = CSSearchableItemAttributeSet(contentType: UTType.text)
        attrs.title = atom.oneLiner.isEmpty ? atom.type.label : atom.oneLiner
        attrs.contentDescription = String(atom.displayContent.prefix(2000))
        attrs.keywords = atom.tags.map(\.value) + [atom.type.rawValue, "nous"]
        attrs.contentCreationDate = atom.createdAt
        attrs.contentModificationDate = atom.updatedAt

        let item = CSSearchableItem(
            uniqueIdentifier: atom.id.uuidString,
            domainIdentifier: "atom",
            attributeSet: attrs
        )
        // Expire 90 days after last update — keeps the system index lean for
        // dormant users. Active atoms get re-touched on every refine + tag change.
        item.expirationDate = Calendar.current.date(byAdding: .day, value: 90, to: atom.updatedAt)
        return item
    }
}
