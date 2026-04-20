import SwiftUI

/// Specimen slab. Full-screen surface for one atom.
/// - Subtle phosphor halo backdrop tinted by the atom's type (top-leading anchor).
/// - Header bar with type dot, kind label, timestamp, close. Hairline divider below.
/// - Body fills with cap width for readability; long-press toggles raw↔refined; tap edits.
/// - Related dock at bottom, above safe-area + orb keep-out (orb is hidden by RootView when open).
struct AtomDetailView: View {
    let atom: AtomSnapshot
    let related: [AtomSnapshot]
    let store: AtomStore
    var morphNS: Namespace.ID? = nil
    let onClose: () -> Void

    @State private var editMode = false
    @State private var editBuffer = ""
    @State private var showRaw = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .top) {
            // Backdrop: ink + phosphor halo from upper-left tinted by atom type.
            backdrop

            VStack(spacing: 0) {
                header
                Divider()
                    .frame(height: 0.5)
                    .overlay(NSColorToken.textGhost.opacity(0.35))
                bodyArea
                if !related.isEmpty {
                    relatedDock
                }
            }
        }
        .background(NSColorToken.inkVoid.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .transition(.opacity)
    }

    // MARK: Backdrop

    private var backdrop: some View {
        ZStack {
            // Atom-type tinted glow, top-leading. Pre-blurred radial = no per-frame Gaussian cost.
            RadialGradient(
                colors: [atom.type.phosphor.opacity(0.22), .clear],
                center: UnitPoint(x: 0.18, y: 0.18),
                startRadius: 0,
                endRadius: 520
            )
            // Bottom counter-glow, very faint, balances composition.
            RadialGradient(
                colors: [atom.type.phosphor.opacity(0.06), .clear],
                center: UnitPoint(x: 0.85, y: 1.05),
                startRadius: 0,
                endRadius: 360
            )
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: NSpace.md) {
            AtomDot(type: atom.type, size: 10)
            Text(atom.type.label)
                .font(NFont.mono(10))
                .foregroundStyle(NSColorToken.textTertiary)
                .textCase(.uppercase)
                .tracking(0.10)
            Spacer()
            Text(createdString)
                .font(NFont.mono(11))
                .foregroundStyle(NSColorToken.textTertiary)
                .monospacedDigit()
            Button(action: close) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(NSColorToken.textSecondary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, NSpace.xl)
        .padding(.top, NSpace.lg)
        .padding(.bottom, NSpace.md)
    }

    // MARK: Body

    @ViewBuilder private var bodyArea: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NSpace.lg) {
                if editMode {
                    TextEditor(text: $editBuffer)
                        .font(NFont.detailBody(18))
                        .foregroundStyle(NSColorToken.textPrimary)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 240, alignment: .topLeading)
                } else {
                    CrossFadeText(
                        raw: atom.rawContent,
                        refined: atom.refinedContent,
                        showRaw: showRaw,
                        isRefining: atom.isRefining
                    )
                    .font(NFont.detailBody(18))
                    .foregroundStyle(NSColorToken.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineSpacing(4)
                    .onTapGesture { beginEdit() }
                    .onLongPressGesture(minimumDuration: 0.35) {
                        withAnimation(.nEaseInOutQuint) { showRaw.toggle() }
                        Haptics.shared.softTick()
                    }
                }

                if !atom.tags.isEmpty { tagRow }

                modeFooter
            }
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, NSpace.xl)
            .padding(.top, NSpace.xl)
            .padding(.bottom, NSpace.xxl)
        }
        .scrollIndicators(.hidden)
    }

    private var tagRow: some View {
        FlexibleTagRow(tags: atom.tags)
    }

    private var modeFooter: some View {
        HStack(spacing: NSpace.sm) {
            if atom.refinedContent != nil {
                Text(showRaw ? "// raw" : "// refined")
                    .font(NFont.mono(10))
                    .foregroundStyle(NSColorToken.textGhost)
                Text("· long-press to toggle")
                    .font(NFont.mono(10))
                    .foregroundStyle(NSColorToken.textGhost.opacity(0.6))
            } else if atom.isRefining {
                Text("// refining…")
                    .font(NFont.mono(10))
                    .foregroundStyle(atom.type.phosphor.opacity(0.7))
            }
            Spacer()
            if atom.type == .task {
                Button(action: { store.toggleTask(id: atom.id); Haptics.shared.softTick() }) {
                    Text(atom.taskDone == true ? "// done" : "// open")
                        .font(NFont.mono(10))
                        .foregroundStyle(atom.taskDone == true
                                         ? NSColorToken.textGhost
                                         : NSColorToken.Phos.green)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, NSpace.md)
    }

    // MARK: Related dock

    private var relatedDock: some View {
        VStack(alignment: .leading, spacing: NSpace.sm) {
            Divider()
                .frame(height: 0.5)
                .overlay(NSColorToken.textGhost.opacity(0.25))
            Text("// semantically close")
                .font(NFont.mono(10))
                .foregroundStyle(NSColorToken.textTertiary)
                .padding(.horizontal, NSpace.xl)
                .padding(.top, NSpace.md)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: NSpace.md) {
                    ForEach(related) { r in
                        relatedCard(r)
                    }
                }
                .padding(.horizontal, NSpace.xl)
                .padding(.bottom, NSpace.lg)
            }
        }
        .background(NSColorToken.inkPaper.opacity(0.55))
    }

    private func relatedCard(_ r: AtomSnapshot) -> some View {
        Button(action: { /* RootView handles selection via separate path; keep card non-interactive for now */ }) {
            VStack(alignment: .leading, spacing: NSpace.xs) {
                HStack(spacing: NSpace.xs) {
                    AtomDot(type: r.type, size: 6)
                    Text(r.type.label)
                        .font(NFont.mono(9))
                        .foregroundStyle(NSColorToken.textTertiary)
                        .textCase(.uppercase)
                        .tracking(0.10)
                }
                Text(r.oneLiner)
                    .font(NFont.body(13))
                    .foregroundStyle(NSColorToken.textSecondary)
                    .lineLimit(4)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 200, alignment: .topLeading)
            .padding(NSpace.md)
            .background(NSColorToken.inkRaised)
            .overlay(
                Rectangle()
                    .stroke(NSColorToken.textGhost.opacity(0.25), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: Helpers

    private var createdString: String {
        atom.createdAt
            .formatted(.dateTime.month(.abbreviated).day().hour().minute())
            .lowercased()
            .replacingOccurrences(of: ",", with: " at")
    }

    private func close() {
        if editMode { commitEdit() }
        withAnimation(.nDrawer) { onClose() }
    }
    private func beginEdit() {
        editBuffer = showRaw ? atom.rawContent : atom.displayContent
        editMode = true
    }
    private func commitEdit() {
        let buf = editBuffer
        editMode = false
        if buf != atom.displayContent { store.updateRaw(id: atom.id, newContent: buf) }
    }
}

/// Wrapping tag row.
private struct FlexibleTagRow: View {
    let tags: [SmartTag]
    var body: some View {
        // Simple wrap via Layout proxy; for v1 use HStack with wrap behavior via fixedSize.
        HStack(spacing: NSpace.sm) {
            ForEach(tags, id: \.self) { tag in
                Text(tag.value)
                    .font(NFont.monoSmall(10))
                    .foregroundStyle(NSColorToken.textSecondary)
                    .textCase(.uppercase)
                    .tracking(0.08)
                    .padding(.horizontal, NSpace.sm)
                    .padding(.vertical, 4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 2)
                            .stroke(NSColorToken.textGhost, lineWidth: 0.5)
                    )
            }
        }
    }
}
