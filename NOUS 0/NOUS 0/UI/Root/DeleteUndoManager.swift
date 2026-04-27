import SwiftUI

/// Manages the 4-second undo window for atom deletions.
///
/// Flow: scheduleDelete → atom hidden in stream → 4s timer → commit (real .deleted event).
/// If undo() fires before timer, the atom reappears and no event is emitted.
/// Only one pending deletion at a time; scheduling a second flushes the first immediately.
@Observable
@MainActor
final class DeleteUndoManager {
    private(set) var pendingAtom: AtomSnapshot? = nil
    private var commitTask: Task<Void, Never>?

    func scheduleDelete(atom: AtomSnapshot, store: AtomStore) {
        flush(store: store)
        store.stagePendingDelete(id: atom.id)
        pendingAtom = atom
        Haptics.shared.heavyThud()
        commitTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, !Task.isCancelled else { return }
            self.commit(store: store)
        }
    }

    func undo(store: AtomStore) {
        commitTask?.cancel()
        commitTask = nil
        if let atom = pendingAtom {
            store.cancelPendingDelete(id: atom.id)
            pendingAtom = nil
        }
        Haptics.shared.softTick()
    }

    /// Commit any pending deletion immediately (e.g. app background, second delete).
    func flush(store: AtomStore) {
        commitTask?.cancel()
        commitTask = nil
        if let atom = pendingAtom {
            store.cancelPendingDelete(id: atom.id)
            store.delete(id: atom.id)
            pendingAtom = nil
        }
    }

    private func commit(store: AtomStore) {
        guard let atom = pendingAtom else { return }
        store.cancelPendingDelete(id: atom.id)
        store.delete(id: atom.id)
        pendingAtom = nil
    }
}
