import SwiftUI

/// Body placeholder for the atom detail surface when there is no displayable
/// body — while refining, after a refine failure, or when nothing was captured.
///
/// Replaces a blank pane (or a lone heading rendered over emptiness) with a
/// quiet, legible status: a phosphor dot, a `// status` line, and a one-line
/// hint. Shared by both the iOS and macOS detail views — no platform branch.
struct AtomBodyPlaceholder: View {
    enum Kind { case refining, failed, empty }

    let kind: Kind
    let type: AtomType
    var onRetry: (() -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: NSpace.sm) {
            HStack(spacing: NSpace.sm) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 5, height: 5)
                    .opacity(isPulsing ? (pulse ? 1.0 : 0.3) : 1.0)
                    .animation(pulseAnimation, value: pulse)
                Text(title)
                    .font(NFont.mono(12))
                    .foregroundStyle(NSColorToken.textSecondary)
                    .tracking(0.8)
            }

            Text(hint)
                .font(NFont.mono(11))
                .foregroundStyle(NSColorToken.textGhostDim)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(3)

            if kind == .failed, let onRetry {
                Button(action: onRetry) {
                    Text("// retry")
                        .font(NFont.mono(11))
                        .foregroundStyle(type.phosphor)
                }
                .buttonStyle(.plain)
                .padding(.top, NSpace.xs)
                .accessibilityLabel("Retry refine")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, NSpace.xl)
        .onAppear { pulse = true }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(hint)")
    }

    // MARK: – Content

    private var title: String {
        switch kind {
        case .refining: "// refining…"
        case .failed:   "// refine failed"
        case .empty:    type == .meeting ? "// no transcript captured" : "// nothing captured yet"
        }
    }

    private var hint: String {
        switch kind {
        case .refining:
            type == .meeting
                ? "Transcribing and summarizing the session. Turns appear here as they're processed."
                : "Distilling your capture. This usually takes a few seconds."
        case .failed:
            "Couldn't process this capture. Your raw text is safe — retry when ready."
        case .empty:
            type == .meeting
                ? "This session ended without any captions, so there was nothing to summarize."
                : "There's no content in this atom yet."
        }
    }

    private var dotColor: Color {
        switch kind {
        case .refining: type.phosphor
        case .failed:   NSColorToken.Phos.orange
        case .empty:    NSColorToken.textGhost
        }
    }

    // MARK: – Motion

    private var isPulsing: Bool { kind == .refining && !reduceMotion }

    private var pulseAnimation: Animation? {
        isPulsing ? .easeInOut(duration: 1.1).repeatForever(autoreverses: true) : nil
    }
}
