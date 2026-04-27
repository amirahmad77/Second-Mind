import SwiftUI

/// Keyboard-anchored toolbar for inserting markdown into a text buffer.
///
/// Six instruments: H1 / H2 / bullet / checkbox / link / code. Each tap
/// inserts the relevant markdown literal at the end of the buffer (SwiftUI's
/// `TextEditor` has no public cursor API, so end-of-buffer is the v1 contract;
/// users learn that toolbar = "append a fresh line in this format").
///
/// Sits above LinkPickerBar in the safe-area inset stack — link picker is
/// a sibling that owns its own bar, this one owns the formatting bar.
///
/// Visual rhythm:
///   - 44pt height (Apple HIG min tap row)
///   - inkRaised background w/ a hairline cyan top edge to read as instrument panel
///   - Each button is 40pt wide w/ mono label, 100ms ease-out scale-down on press
///   - Brief cyan flash on the pressed button after insertion (180ms ease-out)
///     so users see the system "heard" them — Emil's responsiveness rule.
struct MarkdownToolbar: View {
    @Binding var text: String
    /// Optional: when set, hides toolbar if a `[[` is currently open (LinkPickerBar
    /// takes precedence). Pass the same `text` so the toolbar self-hides during
    /// active link picking.
    var hideWhenLinkPickerActive: Bool = true

    @State private var flashedID: String?

    var body: some View {
        if hideWhenLinkPickerActive && hasOpenLink {
            EmptyView()
        } else {
            HStack(spacing: 0) {
                instruments
                Spacer(minLength: 0)
                Text("↓ end")
                    .font(NFont.mono(9))
                    .foregroundStyle(NSColorToken.textGhost.opacity(0.45))
                    .padding(.trailing, NSpace.md)
            }
            .frame(height: 44)
            .background(NSColorToken.inkRaised)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(NSColorToken.Phos.cyan.opacity(0.30))
                    .frame(height: 0.75)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: - Instruments

    private var instruments: some View {
        HStack(spacing: 0) {
            tool("H1",   id: "h1")              { insertHeading(level: 1) }
            tool("H2",   id: "h2")              { insertHeading(level: 2) }
            tool("•",    id: "bul")             { insertLinePrefix("- ") }
            tool("☐",    id: "chk")             { insertLinePrefix("- [ ] ") }
            tool("[[",   id: "lnk", accent: true) { insertInline("[[", "") }
            tool("`",    id: "code")            { insertWrap("`", "`") }
        }
    }

    @ViewBuilder
    private func tool(_ label: String, id: String, accent: Bool = false, action: @escaping () -> Void) -> some View {
        Button {
            action()
            flash(id: id)
            Haptics.shared.softTick()
        } label: {
            Text(label)
                .font(NFont.mono(13))
                .foregroundStyle(flashedID == id
                                 ? NSColorToken.Phos.cyan
                                 : (accent ? NSColorToken.Phos.cyan.opacity(0.65) : NSColorToken.textSecondary))
                .frame(width: 40, height: 44)
                .background(
                    flashedID == id
                        ? NSColorToken.Phos.cyan.opacity(0.10)
                        : (accent ? NSColorToken.Phos.cyan.opacity(0.05) : Color.clear)
                )
                .contentShape(Rectangle())
                .animation(.easeOut(duration: 0.18), value: flashedID == id)
        }
        .buttonStyle(InstrumentButtonStyle())
    }

    private func flash(id: String) {
        flashedID = id
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 220_000_000)
            if flashedID == id { flashedID = nil }
        }
    }

    // MARK: - Insertions
    //
    // SwiftUI TextEditor has no cursor API in iOS 17, so we append at the end
    // with a leading newline if needed. `insertWrap` and `insertInline` instead
    // append the wrapper at end + position user expectation: "type your text
    // between these markers". Worth revisiting w/ TextField (iOS 17 axis: .vertical)
    // which exposes selection in iOS 18.

    private func insertLinePrefix(_ prefix: String) {
        ensureNewline()
        text.append(prefix)
    }

    private func insertHeading(level: Int) {
        let hashes = String(repeating: "#", count: level)
        ensureNewline()
        text.append("\(hashes) ")
    }

    private func insertInline(_ open: String, _ close: String) {
        // For [[ — caller will type query, LinkPickerBar takes over.
        text.append(open)
    }

    private func insertWrap(_ open: String, _ close: String) {
        text.append("\(open)\(close)")
    }

    private func ensureNewline() {
        guard !text.isEmpty, !text.hasSuffix("\n") else { return }
        text.append("\n")
    }

    // MARK: - Link-picker coexistence

    private var hasOpenLink: Bool {
        guard let openRange = text.range(of: "[[", options: .backwards) else { return false }
        let after = text[openRange.upperBound..<text.endIndex]
        if after.contains("]]") { return false }
        if after.contains(where: \.isNewline) { return false }
        if after.count > 60 { return false }
        return true
    }
}

/// Press feedback: subtle scale + opacity dip. 100ms ease-out (Emil's "buttons
/// must feel responsive to press" — too long feels mushy on a tool button).
private struct InstrumentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1.0)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
    }
}
