import SwiftUI
import Combine
#if canImport(AppKit)
import AppKit
#endif

/// "Pair browser" sheet — iOS side of the Chrome extension handshake.
/// Calls `POST /v1/pair/start` with the current user's id, then shows the
/// returned 6-digit code with a countdown until it expires.
///
/// The user types the code into the NOUS Chrome extension popup, which calls
/// `POST /v1/pair/complete` to mint a long-lived token.
struct PairBrowserSheet: View {
    let userID: UUID
    var backend: NousBackendClient = .init()

    @Environment(\.dismiss) private var dismiss
    @State private var code: String?
    @State private var expiresAt: Date?
    @State private var error: String?
    @State private var isLoading = false
    @State private var now = Date()
    @State private var bridgeCopied = false

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: NSpace.lg) {
            header
            codeBlock
            instructions
            #if os(macOS)
            bridgeTokenSection
            #endif
            Spacer()
            actions
        }
        .padding(NSpace.lg)
        .background(NSColorToken.inkPaper.ignoresSafeArea())
        .task { await mint() }
        .onReceive(ticker) { now = $0 }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: NSpace.sm) {
            Text("PAIR · BROWSER")
                .font(NFont.mono(10))
                .tracking(2)
                .foregroundStyle(NSColorToken.textGhost)
            Text("Enter this code in the NOUS Chrome extension.")
                .font(NFont.body(16))
                .foregroundStyle(NSColorToken.textPrimary)
        }
    }

    @ViewBuilder
    private var codeBlock: some View {
        if let code {
            VStack(spacing: NSpace.xs) {
                Text(formatted(code))
                    .font(.system(size: 44, weight: .semibold, design: .monospaced))
                    .tracking(8)
                    .foregroundStyle(NSColorToken.Phos.cyan)
                    .contentTransition(.numericText())
                Text(countdown)
                    .font(NFont.mono(11))
                    .foregroundStyle(NSColorToken.textGhost)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, NSpace.lg)
        } else if isLoading {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, NSpace.lg)
        } else if let error {
            Text(error)
                .font(NFont.body(13))
                .foregroundStyle(NSColorToken.Phos.amber)
        }
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: NSpace.sm) {
            row("1", "Install the NOUS extension in Chrome.")
            row("2", "Click the NOUS icon in the toolbar.")
            row("3", "Type this 6-digit code and hit Pair.")
        }
    }

    private func row(_ n: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: NSpace.sm) {
            Text(n)
                .font(NFont.mono(11))
                .foregroundStyle(NSColorToken.textGhost)
                .frame(width: 14, alignment: .leading)
            Text(text)
                .font(NFont.body(14))
                .foregroundStyle(NSColorToken.textPrimary)
        }
    }

    private var actions: some View {
        HStack {
            Button("Close") { dismiss() }
                .buttonStyle(.plain)
                .foregroundStyle(NSColorToken.textGhost)
            Spacer()
            Button {
                Task { await mint() }
            } label: {
                Text(code == nil ? "Retry" : "New code")
                    .font(NFont.mono(11))
                    .tracking(1.5)
                    .foregroundStyle(NSColorToken.Phos.cyan)
            }
            .disabled(isLoading)
        }
    }

    #if os(macOS)
    /// Local-bridge shared secret. Separate from the account pairing code above:
    /// this authenticates the localhost:9988 WebSocket so other local processes
    /// or web pages can't drive the Meet bridge. Paste once into the extension's
    /// "Bridge token" field. (Currently optional — soft mode — but pairing now
    /// future-proofs against enforcement being enabled.)
    private var bridgeTokenSection: some View {
        VStack(alignment: .leading, spacing: NSpace.sm) {
            Text("BRIDGE · TOKEN")
                .font(NFont.mono(10))
                .tracking(2)
                .foregroundStyle(NSColorToken.textGhost)
            Text("Paste into the NOUS extension's Bridge token field to secure the localhost connection.")
                .font(NFont.body(13))
                .foregroundStyle(NSColorToken.textGhostDim)
            HStack(spacing: NSpace.sm) {
                Text(MeetBridgeServer.persistedPairingToken)
                    .font(NFont.mono(11))
                    .foregroundStyle(NSColorToken.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer()
                Button(bridgeCopied ? "copied" : "copy") {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(MeetBridgeServer.persistedPairingToken, forType: .string)
                    bridgeCopied = true
                }
                .buttonStyle(.plain)
                .font(NFont.mono(11))
                .tracking(1.5)
                .foregroundStyle(NSColorToken.Phos.cyan)
            }
            .padding(NSpace.sm)
            .background(NSColorToken.inkVoid, in: RoundedRectangle(cornerRadius: 6))
        }
    }
    #endif

    // MARK: helpers

    private func formatted(_ c: String) -> String {
        guard c.count == 6 else { return c }
        let i = c.index(c.startIndex, offsetBy: 3)
        return "\(c[..<i]) \(c[i...])"
    }

    private var countdown: String {
        guard let expiresAt else { return " " }
        let remaining = max(0, Int(expiresAt.timeIntervalSince(now)))
        if remaining == 0 { return "EXPIRED" }
        return "expires in \(remaining / 60):\(String(format: "%02d", remaining % 60))"
    }

    private func mint() async {
        isLoading = true
        error = nil
        do {
            let r = try await backend.pairStart(userID: userID)
            self.code = r.code
            self.expiresAt = r.expires_at
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }
}
