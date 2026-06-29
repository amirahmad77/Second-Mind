import SwiftUI

/// Proactive signals NOUS already computed for an atom, surfaced where you
/// actually look (the stream row) instead of staying buried until you open the
/// detail. All reads are O(1) off cached store dictionaries populated right
/// after refine — cheap enough to render on every visible row.
///
/// One source of truth for both iOS (`AtomRow`) and macOS (`MacAtomRow`) so the
/// signal vocabulary can never drift between platforms.
struct AtomSignals: Equatable {
    /// Auto-suggested links to other atoms (`store.linkSuggestions`).
    let relatesCount: Int
    /// Near-duplicate atoms by embedding similarity (`store.duplicateSuggestions`).
    let duplicateCount: Int

    var hasAny: Bool { relatesCount > 0 || duplicateCount > 0 }

    @MainActor init(atom: AtomSnapshot, store: AtomStore) {
        relatesCount = store.linkSuggestions[atom.id]?.count ?? 0
        duplicateCount = store.duplicateSuggestions[atom.id]?.count ?? 0
    }
}

/// Compact meta-line indicators for an atom's proactive signals, matching the
/// existing `· ← N` backlink grammar. Quiet by default, tinted to the atom's
/// phosphor so they read as "NOUS noticed something" without shouting.
struct AtomSignalChips: View {
    let signals: AtomSignals
    let tint: Color

    var body: some View {
        if signals.relatesCount > 0 {
            chip("≈ \(signals.relatesCount)", color: tint.opacity(0.65))
        }
        if signals.duplicateCount > 0 {
            chip("⧉ \(signals.duplicateCount)", color: NSColorToken.Phos.amber.opacity(0.70))
        }
    }

    @ViewBuilder private func chip(_ text: String, color: Color) -> some View {
        Text("· \(text)")
            .font(NFont.mono(10))
            .foregroundStyle(color)
            .monospacedDigit()
            .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var parts: [String] = []
        if signals.relatesCount > 0 { parts.append("\(signals.relatesCount) related") }
        if signals.duplicateCount > 0 { parts.append("\(signals.duplicateCount) possible duplicate") }
        return parts.joined(separator: ", ")
    }
}
