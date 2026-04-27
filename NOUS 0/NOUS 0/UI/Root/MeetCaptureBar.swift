import SwiftUI

/// Slim status pill shown when the Chrome extension is actively recording a
/// Google Meet. Pulses a phosphor-green dot to signal live capture.
struct MeetCaptureBar: View {
    let session: NousBackendClient.ActiveMeetSession

    @State private var pulsing = false

    var body: some View {
        HStack(spacing: NSpace.xs) {
            Circle()
                .fill(NSColorToken.Phos.green)
                .frame(width: 5, height: 5)
                .scaleEffect(pulsing ? 1.5 : 1.0)
                .opacity(pulsing ? 0.5 : 1.0)
                .animation(
                    .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                    value: pulsing
                )

            Text("// recording meet")
                .font(NFont.mono(10))
                .foregroundStyle(NSColorToken.Phos.green.opacity(0.9))

            if !session.participantSummary.isEmpty {
                Text("·")
                    .font(NFont.mono(10))
                    .foregroundStyle(NSColorToken.textGhost.opacity(0.4))
                Text(session.participantSummary)
                    .font(NFont.mono(10))
                    .foregroundStyle(NSColorToken.textGhost)
                    .lineLimit(1)
            }

            Text("· \(session.segment_count) turns")
                .font(NFont.mono(10))
                .foregroundStyle(NSColorToken.textGhost.opacity(0.5))
        }
        .padding(.horizontal, NSpace.md)
        .padding(.vertical, NSpace.xs)
        .background(
            Capsule()
                .fill(NSColorToken.Phos.green.opacity(0.08))
                .overlay(
                    Capsule()
                        .stroke(NSColorToken.Phos.green.opacity(0.2), lineWidth: 0.5)
                )
        )
        .onAppear { pulsing = true }
    }
}
