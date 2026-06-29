import SwiftUI

/// Quiet "sync is stuck" affordance. Sync is invisible by design, but when events
/// hit the permanent-failure ceiling and stop retrying, silence becomes a flaw —
/// you could be not-syncing and never know. Shows only when `count > 0`; tap to
/// clear quarantine and retry. Shared by iOS and macOS.
struct SyncTroubleBadge: View {
    let count: Int
    var onRetry: () -> Void

    var body: some View {
        if count > 0 {
            Button(action: onRetry) {
                HStack(spacing: NSpace.xs) {
                    Image(systemName: "exclamationmark.icloud")
                        .font(.system(size: 11, weight: .medium))
                    Text("\(count) not synced")
                        .font(NFont.mono(11))
                    Text("· retry")
                        .font(NFont.mono(11))
                        .foregroundStyle(NSColorToken.Phos.amber)
                }
                .foregroundStyle(NSColorToken.textSecondary)
                .padding(.horizontal, NSpace.md)
                .padding(.vertical, NSpace.sm)
                .background(
                    Capsule(style: .continuous)
                        .fill(NSColorToken.inkRaised.opacity(0.92))
                        .overlay(Capsule().strokeBorder(NSColorToken.Phos.amber.opacity(0.35), lineWidth: 1))
                )
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Some changes haven't synced — tap to retry")
            .accessibilityLabel("\(count) changes not synced. Tap to retry.")
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }
}
