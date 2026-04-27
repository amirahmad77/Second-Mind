import SwiftUI

/// Renders an atom body as a stack of styled blocks.
///
/// Block kinds (see MarkdownParser): heading, paragraph, bullet, numbered,
/// checkbox. Inline runs go through MarkdownInline → AttributedString so
/// bold / italic / inline code / `[[wikilinks]]` work everywhere.
///
/// Visual rhythm choices (Kinetic Minimalism, tools-not-posters):
///   - Heading scale stays tight: H1 22, H2 19, H3 16. No marketing-poster jumps.
///   - Bullets use a real `•` glyph in textTertiary so the marker recedes —
///     content does the talking.
///   - Numbered list uses monospaced digits with a fixed-width column so
///     `9.` and `10.` align — Apple Notes parity.
///   - Checkbox is a 16pt phosphor square; tap target is the full row at 36pt
///     min-height. Checked items strike through + dim to textGhost so the
///     remaining open items stay visually dominant — Notion parity.
///   - Inter-block spacing is rhythmic, not flat: heading > para > para > bullet
///     gets natural breathing room from per-block top padding tuned per kind.
struct MarkdownView: View {
    let raw: String
    let store: AtomStore
    let atomID: UUID
    var linkColor: Color = NSColorToken.Phos.cyan
    var onPickAtom: (AtomSnapshot) -> Void

    var body: some View {
        let blocks = MarkdownParser.parse(raw)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { idx, block in
                blockView(for: block, prevKind: idx > 0 ? kind(of: blocks[idx - 1]) : nil)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "nous", url.host == "atom" else { return .systemAction }
            let idStr = String(url.path.dropFirst())
            guard let uuid = UUID(uuidString: idStr), let atom = store.atoms[uuid] else {
                Haptics.shared.softTick()
                return .handled
            }
            onPickAtom(atom)
            return .handled
        })
    }

    // MARK: - Block dispatch

    @ViewBuilder
    private func blockView(for block: MarkdownParser.Block, prevKind: BlockKind?) -> some View {
        let topPad = topPadding(for: kind(of: block), after: prevKind)
        switch block {
        case .heading(let level, let inline):
            heading(level: level, inline: inline)
                .padding(.top, topPad)
        case .paragraph(let inline):
            paragraph(inline: inline)
                .padding(.top, topPad)
        case .bullet(let inline):
            bullet(inline: inline)
                .padding(.top, topPad)
        case .numbered(let n, let inline):
            numbered(n: n, inline: inline)
                .padding(.top, topPad)
        case .checkbox(let checked, let lineIndex, let inline):
            checkbox(checked: checked, lineIndex: lineIndex, inline: inline)
                .padding(.top, topPad)
        }
    }

    // MARK: - Heading

    @ViewBuilder
    private func heading(level: Int, inline: String) -> some View {
        let size: CGFloat = level == 1 ? 22 : (level == 2 ? 19 : 16)
        let attr = MarkdownInline.attributed(inline, store: store, linkColor: linkColor)
        Text(attr)
            .nDynamicBody(size, weight: .semibold)
            .foregroundStyle(NSColorToken.textPrimary)
            .tracking(level == 3 ? 0.4 : 0)
            .textCase(level == 3 ? .uppercase : nil)
            .lineSpacing(2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Paragraph

    @ViewBuilder
    private func paragraph(inline: String) -> some View {
        let attr = MarkdownInline.attributed(inline, store: store, linkColor: linkColor)
        Text(attr)
            .nDynamicBody(17)
            .foregroundStyle(NSColorToken.textPrimary)
            .lineSpacing(4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Bullet

    @ViewBuilder
    private func bullet(inline: String) -> some View {
        let attr = MarkdownInline.attributed(inline, store: store, linkColor: linkColor)
        HStack(alignment: .firstTextBaseline, spacing: NSpace.sm) {
            Text("•")
                .nDynamicBody(17)
                .foregroundStyle(NSColorToken.textTertiary)
                .frame(width: 14, alignment: .center)
            Text(attr)
                .nDynamicBody(17)
                .foregroundStyle(NSColorToken.textPrimary)
                .lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Numbered

    @ViewBuilder
    private func numbered(n: Int, inline: String) -> some View {
        let attr = MarkdownInline.attributed(inline, store: store, linkColor: linkColor)
        HStack(alignment: .firstTextBaseline, spacing: NSpace.sm) {
            Text("\(n).")
                .font(NFont.mono(13))
                .foregroundStyle(NSColorToken.textTertiary)
                .monospacedDigit()
                .frame(width: 22, alignment: .trailing)
            Text(attr)
                .nDynamicBody(17)
                .foregroundStyle(NSColorToken.textPrimary)
                .lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Checkbox (interactive)

    @ViewBuilder
    private func checkbox(checked: Bool, lineIndex: Int, inline: String) -> some View {
        let attr = MarkdownInline.attributed(inline, store: store, linkColor: linkColor)
        Button {
            store.toggleChecklistItem(id: atomID, lineIndex: lineIndex)
            Haptics.shared.softTick()
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: NSpace.sm) {
                CheckboxGlyph(checked: checked)
                    .frame(width: 16, height: 16, alignment: .center)
                    .padding(.top, 2) // optical alignment with text baseline
                Text(attr)
                    .nDynamicBody(17)
                    .foregroundStyle(checked ? NSColorToken.textGhost : NSColorToken.textPrimary)
                    .strikethrough(checked, color: NSColorToken.textGhost)
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 36) // tap-target floor
            .contentShape(Rectangle())
        }
        .buttonStyle(CheckboxRowStyle())
    }

    // MARK: - Spacing rhythm

    private enum BlockKind: Hashable { case h1, h2, h3, para, bullet, numbered, checkbox }
    private func kind(of b: MarkdownParser.Block) -> BlockKind {
        switch b {
        case .heading(let level, _): return level == 1 ? .h1 : (level == 2 ? .h2 : .h3)
        case .paragraph: return .para
        case .bullet: return .bullet
        case .numbered: return .numbered
        case .checkbox: return .checkbox
        }
    }

    /// Top padding that gives each block a sense of where it stands.
    /// First block (prev=nil) gets no padding — caller supplies surrounding inset.
    private func topPadding(for current: BlockKind, after prev: BlockKind?) -> CGFloat {
        guard let prev else { return 0 }
        // Headings always get extra air above so they read as dividers.
        switch current {
        case .h1: return NSpace.xl
        case .h2: return NSpace.lg
        case .h3: return NSpace.md
        default: break
        }
        // Same-kind list items hug; switching kinds gets a small breath.
        if current == prev { return NSpace.xs }
        return NSpace.md
    }
}

// MARK: - Checkbox glyph

/// Small phosphor square. Empty = hairline outline. Checked = filled w/ inset
/// "fill" using the green phosphor — readable at 16pt without a heavy SF symbol.
private struct CheckboxGlyph: View {
    let checked: Bool

    var body: some View {
        ZStack {
            // Outline always present; outline color brightens when checked.
            Rectangle()
                .stroke(
                    checked
                        ? NSColorToken.Phos.green.opacity(0.85)
                        : NSColorToken.textTertiary,
                    lineWidth: 1
                )
            if checked {
                Rectangle()
                    .fill(NSColorToken.Phos.green.opacity(0.18))
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(NSColorToken.Phos.green)
            }
        }
        .frame(width: 14, height: 14) // glyph itself; outer frame supplies hit area
        .animation(.easeOut(duration: 0.18), value: checked)
    }
}

/// Press feedback: gentle scale + opacity dip. Avoids the standard system
/// pressed-state which would fight Kinetic Minimalism.
private struct CheckboxRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1.0)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}
