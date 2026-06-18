import SwiftUI

/// Specimen slab. Full-screen surface for one atom.
/// Editorial layout: floating controls (ghost) → scrolling content (type identity →
/// body → status → tags) → related strip (pinned, feels continuous).
struct AtomDetailView: View {
    let atom: AtomSnapshot
    let related: [AtomSnapshot]
    let store: AtomStore
    var morphNS: Namespace.ID? = nil
    let onClose: () -> Void
    var onDelete: ((AtomSnapshot) -> Void)? = nil
    var onPickRelated: ((AtomSnapshot) -> Void)? = nil

    @State private var editMode = false
    @State private var editBuffer = ""
    @State private var showRaw = false
    @State private var refinePulse = false
    @State private var addingTag = false
    @State private var tagInput = ""
    @State private var contentBlur: CGFloat = 0
    @State private var scanlineY: CGFloat = -1
    @State private var showTypePicker = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topTrailing) {
            backdrop

            VStack(spacing: 0) {
                controls
                    .padding(.horizontal, NSpace.lg)
                    .padding(.top, NSpace.md)

                contentScroll

                if !related.isEmpty {
                    relatedDock
                }
            }
        }
        .background(NSColorToken.inkVoid.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .transition(reduceMotion
            ? .opacity
            : .asymmetric(
                insertion: .opacity.combined(with: .move(edge: .bottom)),
                removal: .opacity.combined(with: .move(edge: .bottom))
              )
        )
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) {
                refinePulse = true
            }
        }
    }

    // MARK: – Backdrop

    private var backdrop: some View {
        ZStack {
            // Primary halo — top-left, keyed to atom type
            RadialGradient(
                colors: [atom.type.phosphor.opacity(0.18), .clear],
                center: UnitPoint(x: 0.08, y: 0.06),
                startRadius: 0,
                endRadius: 520
            )
            // Secondary whisper — bottom-right, much softer
            RadialGradient(
                colors: [atom.type.phosphor.opacity(0.05), .clear],
                center: UnitPoint(x: 0.95, y: 1.0),
                startRadius: 0,
                endRadius: 320
            )
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .animation(.spring(response: 0.7, dampingFraction: 0.8), value: atom.type)
    }

    // MARK: – Controls (ghost, top-right)

    private var controls: some View {
        HStack(spacing: NSpace.xs) {
            Spacer(minLength: 0)
            if editMode {
                Button(action: commitEdit) {
                    Text("done")
                        .font(NFont.mono(11))
                        .foregroundStyle(atom.type.phosphor.opacity(0.75))
                        .padding(.horizontal, NSpace.sm)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(atom.type.phosphor.opacity(0.08))
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Done editing")
            } else {
                Button(action: deleteAtom) {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .light))
                        .foregroundStyle(NSColorToken.textGhost.opacity(0.6))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete atom")
                .accessibilityHint("Removes this atom permanently")

                shareControl
            }
            Button(action: close) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 13, weight: .light))
                    .foregroundStyle(NSColorToken.textTertiary)
                    .frame(width: 44, height: 44)
                    .background(
                        Circle()
                            .fill(NSColorToken.inkRaised.opacity(0.55))
                    )
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
    }

    // MARK: – Share

    /// Ghost share affordance matching the top-right control idiom. Exports the
    /// current atom as Markdown. `ShareLink` offers both the inline text and the
    /// generated `.md` temp file (the system share sheet chooses per target).
    @ViewBuilder private var shareControl: some View {
        let md = AtomExport.markdown(atom)
        let item = SharePreview("\(atom.type.label) · note", image: Image(systemName: "doc.text"))
        if let fileURL = AtomExport.temporaryFile(name: "\(AtomExport.fileStem(for: atom)).md", contents: md) {
            ShareLink(item: fileURL, subject: Text("\(atom.type.label) · note"), message: Text(md), preview: item) {
                shareGlyph
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Share atom")
            .accessibilityHint("Exports this atom as Markdown")
        } else {
            // Fallback: share the Markdown text directly if the temp file couldn't be written.
            ShareLink(item: md, subject: Text("\(atom.type.label) · note"), preview: item) {
                shareGlyph
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Share atom")
            .accessibilityHint("Exports this atom as Markdown")
        }
    }

    private var shareGlyph: some View {
        Image(systemName: "square.and.arrow.up")
            .font(.system(size: 11, weight: .light))
            .foregroundStyle(NSColorToken.textGhost.opacity(0.6))
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }

    // MARK: – Content scroll

    private var contentScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                typeBlock
                    .padding(.horizontal, NSpace.xl)
                    .padding(.top, NSpace.x4)
                    .padding(.bottom, NSpace.xxxl)

                bodyContent
                    .padding(.horizontal, NSpace.xl)

                statusLine
                    .padding(.horizontal, NSpace.xl)
                    .padding(.top, NSpace.xl)

                tagBlock
                    .padding(.horizontal, NSpace.xl)
                    .padding(.top, NSpace.xxxl)

                Color.clear.frame(height: NSpace.x5)
            }
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: – Type block

    private var typeBlock: some View {
        VStack(alignment: .leading, spacing: NSpace.md) {
            // Dot + optional pulse
            HStack(alignment: .center, spacing: NSpace.xs) {
                AtomDot(type: atom.type, size: 14)
                .shadow(color: atom.type.phosphor.opacity(0.45), radius: 10, x: 0, y: 0)

                if atom.isRefining {
                    Circle()
                        .fill(atom.type.phosphor)
                        .frame(width: 3, height: 3)
                        .opacity(refinePulse ? 0.90 : 0.15)
                        .animation(
                            reduceMotion ? nil : .easeInOut(duration: 2.2).repeatForever(autoreverses: true),
                            value: refinePulse
                        )
                }
            }

            // Type label — tappable for manual override
            Button {
                guard !atom.isRefining else { return }
                withAnimation(.nEaseOutQuint) { showTypePicker.toggle() }
                Haptics.shared.softTick()
            } label: {
                HStack(spacing: NSpace.xs) {
                    Text(atom.type.label)
                        .font(NFont.mono(10))
                        .foregroundStyle(
                            atom.isRefining
                                ? atom.type.phosphor.opacity(refinePulse ? 0.80 : 0.30)
                                : atom.type.phosphor.opacity(0.70)
                        )
                        .textCase(.uppercase)
                        .tracking(3.2)
                        .animation(
                            reduceMotion ? nil : .easeInOut(duration: 2.2).repeatForever(autoreverses: true),
                            value: refinePulse
                        )
                        .contentTransition(.opacity)
                        .animation(.nEaseOutQuint, value: atom.type)
                    if !atom.isRefining {
                        Image(systemName: showTypePicker ? "chevron.up" : "chevron.down")
                            .font(.system(size: 7.5, weight: .light))
                            .foregroundStyle(atom.type.phosphor.opacity(0.30))
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(atom.isRefining ? "Type: \(atom.type.label), refining" : "Type: \(atom.type.label)")
            .accessibilityHint(atom.isRefining ? "" : "Double-tap to change atom type")

            // Inline type picker
            if showTypePicker {
                DetailTypePicker(current: atom.type) { newType in
                    store.setType(id: atom.id, to: newType)
                    withAnimation(.nEaseOutQuint) { showTypePicker = false }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.93, anchor: .topLeading)))
                .padding(.top, NSpace.xs)
            }

            // Timestamp — comfortably below the label
            Text(createdString)
                .font(NFont.mono(10))
                .foregroundStyle(NSColorToken.textGhostDim)
                .monospacedDigit()
                .padding(.top, NSpace.xs)
        }
    }

    // MARK: – Body content

    @ViewBuilder private var bodyContent: some View {
        if editMode {
            TextEditor(text: $editBuffer)
                .font(NFont.detailBody(19))
                .foregroundStyle(NSColorToken.textPrimary)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 260, alignment: .topLeading)
                .lineSpacing(7)
        } else {
            let content = showRaw ? atom.rawContent : atom.displayContent
            MarkdownView(
                raw: content,
                store: store,
                atomID: atom.id,
                linkColor: atom.type.phosphor,
                onPickAtom: { picked in onPickRelated?(picked) }
            )
            .blur(radius: contentBlur)
            .overlay {
                // Phosphor scanline while AI is processing
                if atom.isRefining {
                    GeometryReader { geo in
                        Rectangle()
                            .fill(atom.type.phosphor.opacity(0.15))
                            .frame(height: 1.5)
                            .blur(radius: 3)
                            .offset(y: geo.size.height * max(0, scanlineY))
                            .animation(
                                reduceMotion ? nil : .linear(duration: 1.6).repeatForever(autoreverses: false),
                                value: scanlineY
                            )
                            .onAppear { scanlineY = 1.1 }
                            .onDisappear { scanlineY = -1 }
                    }
                    .allowsHitTesting(false)
                }
            }
            .onTapGesture { beginEdit() }
            .onLongPressGesture(minimumDuration: 0.35) {
                withAnimation(.nEaseInOutQuint) { showRaw.toggle() }
                Haptics.shared.softTick()
            }
            .onChange(of: content) { _, _ in
                withAnimation(.nEaseOutQuint) { contentBlur = 3 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                    withAnimation(.nEaseOutQuint) { contentBlur = 0 }
                }
            }
            .accessibilityLabel(atom.isRefining ? "Content, refining" : (showRaw ? "Raw content" : "Refined content"))
            .accessibilityHint("Double-tap to edit. Touch and hold to toggle between raw and refined.")
            .accessibilityAction(named: "Toggle raw/refined") {
                withAnimation(.nEaseInOutQuint) { showRaw.toggle() }
                Haptics.shared.softTick()
            }
            .accessibilityAction(named: "Edit") { beginEdit() }
        }
    }

    // MARK: – Status line

    private var statusLine: some View {
        HStack(spacing: NSpace.md) {
            Group {
                if atom.isRefining {
                    HStack(spacing: 6) {
                        // Animated phosphor bar
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Rectangle()
                                    .fill(atom.type.phosphor.opacity(0.10))
                                    .frame(height: 1)
                                Rectangle()
                                    .fill(atom.type.phosphor.opacity(refinePulse ? 0.55 : 0.20))
                                    .frame(width: geo.size.width * 0.45, height: 1)
                                    .offset(x: refinePulse ? geo.size.width * 0.55 : 0)
                                    .animation(
                                        reduceMotion ? nil : .easeInOut(duration: 2.2).repeatForever(autoreverses: true),
                                        value: refinePulse
                                    )
                            }
                        }
                        .frame(height: 1)
                        .frame(maxWidth: 48)

                        Text("refining")
                            .font(NFont.mono(10))
                            .foregroundStyle(
                                atom.type.phosphor.opacity(refinePulse ? 0.80 : 0.35)
                            )
                            .animation(
                                reduceMotion ? nil : .easeInOut(duration: 2.2).repeatForever(autoreverses: true),
                                value: refinePulse
                            )
                            .tracking(1.2)
                    }
                } else if atom.refineFailed {
                    refineFailedRow
                } else if atom.refinedContent != nil {
                    HStack(spacing: 5) {
                        Text(showRaw ? "raw" : "refined")
                            .font(NFont.mono(10))
                            .foregroundStyle(NSColorToken.textTertiary)
                            .tracking(1.0)
                        Text("· hold to toggle")
                            .font(NFont.mono(10))
                            .foregroundStyle(NSColorToken.textGhostDim)
                    }
                }
            }
            Spacer(minLength: 0)
            if atom.type == .task {
                taskToggle
            }
        }
    }

    // Refine-failure affordance — surfaces a silent give-up and offers a manual retry.
    private var refineFailedRow: some View {
        HStack(spacing: NSpace.sm) {
            Text("// refine failed")
                .font(NFont.mono(10))
                .foregroundStyle(NSColorToken.Phos.orange.opacity(0.80))
                .tracking(1.0)
            Button(action: { store.retryRefine(id: atom.id); Haptics.shared.softTick() }) {
                Text("retry")
                    .font(NFont.mono(10))
                    .foregroundStyle(NSColorToken.Phos.orange)
                    .tracking(1.0)
                    .padding(.horizontal, NSpace.sm)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(NSColorToken.Phos.orange.opacity(0.10))
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Retry refine")
            .accessibilityHint("Refinement failed. Double-tap to try again.")
        }
        .accessibilityElement(children: .contain)
    }

    private var taskToggle: some View {
        Button(action: { store.toggleTask(id: atom.id); Haptics.shared.softTick() }) {
            HStack(spacing: 6) {
                ZStack {
                    Circle()
                        .strokeBorder(
                            atom.taskDone == true ? NSColorToken.textGhost : NSColorToken.Phos.green,
                            lineWidth: 1
                        )
                    if atom.taskDone == true {
                        Circle()
                            .fill(NSColorToken.Phos.green.opacity(0.25))
                            .padding(3)
                    }
                }
                .frame(width: 13, height: 13)
                Text(atom.taskDone == true ? "done" : "open")
                    .font(NFont.mono(10))
                    .foregroundStyle(
                        atom.taskDone == true ? NSColorToken.textGhost : NSColorToken.Phos.green
                    )
            }
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(atom.taskDone == true ? "Task complete" : "Task open")
        .accessibilityHint("Double-tap to toggle task status")
        .accessibilityAddTraits(atom.taskDone == true ? .isSelected : [])
    }

    // MARK: – Tag block

    private var tagBlock: some View {
        VStack(alignment: .leading, spacing: NSpace.sm) {
            Text("tags")
                .font(NFont.mono(9))
                .foregroundStyle(NSColorToken.textGhostDim)
                .tracking(2.0)
                .textCase(.uppercase)

            if !atom.tags.isEmpty {
                TagFlowLayout(spacing: NSpace.sm) {
                    ForEach(atom.tags, id: \.self) { tag in
                        HStack(spacing: 5) {
                            Text(tag.value)
                                .font(NFont.monoSmall(10))
                                .foregroundStyle(NSColorToken.textTertiary)
                                .tracking(1.0)
                            Button(action: { store.removeTag(id: atom.id, tag: tag.value) }) {
                                Image(systemName: "xmark")
                                    .font(.system(size: 7, weight: .medium))
                                    .foregroundStyle(NSColorToken.textGhost.opacity(0.60))
                                    // Expand the tap target without enlarging the glyph or the
                                    // chip row: pad outward for hit-testing, then negate the
                                    // padding so layout footprint is unchanged. Keeps the chip
                                    // row at its drawn height while giving the xmark generous slop.
                                    .frame(width: 8, height: 8)
                                    .padding(NSpace.md)
                                    .contentShape(Rectangle())
                                    .padding(-NSpace.md)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove tag \(tag.value)")
                        }
                        .padding(.horizontal, NSpace.sm)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(atom.type.phosphor.opacity(0.05))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(NSColorToken.textGhost.opacity(0.30), lineWidth: 0.5)
                        )
                    }
                }
                .padding(.top, NSpace.xs)
            }

            if addingTag {
                HStack(spacing: NSpace.sm) {
                    TextField("", text: $tagInput, prompt: Text("tag name").foregroundColor(NSColorToken.textGhost))
                        .font(NFont.monoSmall(11))
                        .foregroundStyle(NSColorToken.textPrimary)
                        .autocorrectionDisabled()
                        #if os(iOS) || os(visionOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .onSubmit { commitTag() }
                        .padding(.horizontal, NSpace.sm)
                        .padding(.vertical, 5)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(atom.type.phosphor.opacity(0.35), lineWidth: 0.5)
                        )
                        .frame(minWidth: 90, maxWidth: 180)
                    Button(action: { addingTag = false; tagInput = "" }) {
                        Text("cancel")
                            .font(NFont.mono(9))
                            .foregroundStyle(NSColorToken.textGhostDim)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, NSpace.xs)
            } else {
                Button(action: { withAnimation(.nEaseOutQuint) { addingTag = true } }) {
                    HStack(spacing: 4) {
                        Text("+")
                            .font(.system(size: 13, weight: .light, design: .monospaced))
                        Text("add tag")
                            .font(NFont.mono(9))
                    }
                    .foregroundStyle(NSColorToken.textGhostDim)
                }
                .buttonStyle(.plain)
                .padding(.top, NSpace.xs)
            }
        }
    }

    private func commitTag() {
        let trimmed = tagInput.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !trimmed.isEmpty { store.addTag(id: atom.id, tag: trimmed) }
        tagInput = ""
        addingTag = false
    }

    // MARK: – Related dock

    private var relatedDock: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Fade-in from void, then a thin hairline
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [NSColorToken.textGhost.opacity(0), NSColorToken.textGhost.opacity(0.10)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 0.5)
                .padding(.horizontal, NSpace.xl)
                .padding(.top, NSpace.lg)

            Text("related")
                .font(NFont.mono(9))
                .foregroundStyle(NSColorToken.textGhostDim)
                .tracking(2.0)
                .textCase(.uppercase)
                .padding(.horizontal, NSpace.xl)
                .padding(.top, NSpace.md)
                .padding(.bottom, NSpace.sm)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: NSpace.sm) {
                    ForEach(related) { r in
                        relatedCard(r)
                    }
                }
                .padding(.horizontal, NSpace.xl)
                .padding(.bottom, NSpace.lg)
            }
        }
        .background(
            LinearGradient(
                colors: [
                    NSColorToken.inkVoid.opacity(0.0),
                    NSColorToken.inkVoid.opacity(0.85)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private func relatedCard(_ r: AtomSnapshot) -> some View {
        Button(action: { onPickRelated?(r) }) {
            VStack(alignment: .leading, spacing: NSpace.sm) {
                HStack(spacing: NSpace.xs) {
                    AtomDot(type: r.type, size: 5)
                    Text(r.type.label)
                        .font(NFont.mono(8))
                        .foregroundStyle(r.type.phosphor.opacity(0.50))
                        .textCase(.uppercase)
                        .tracking(1.4)
                }
                Text(r.oneLiner)
                    .font(NFont.body(13))
                    .foregroundStyle(NSColorToken.textSecondary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Fluid card width: 168pt ideal, shrinks to 52% of screen on SE (320pt → ~166pt)
            // Never overflows the horizontal scroll area on any supported device.
            .frame(width: 168, alignment: .topLeading)
            .padding(.vertical, NSpace.md)
            .padding(.horizontal, NSpace.md)
            .background(NSColorToken.inkRaised.opacity(0.70))
            .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(r.type.label): \(r.oneLiner)")
        .accessibilityHint("Double-tap to open related atom")
    }

    // MARK: – Helpers

    private var createdString: String {
        atom.createdAt
            .formatted(.dateTime.month(.abbreviated).day().hour().minute())
            .lowercased()
            .replacingOccurrences(of: ",", with: " ·")
    }

    private func close() {
        if editMode { commitEdit() }
        withAnimation(.nDrawer) { onClose() }
    }
    private func deleteAtom() {
        let a = atom
        withAnimation(.nDrawer) { onClose() }
        onDelete?(a)
    }
    private func beginEdit() {
        editBuffer = showRaw ? atom.rawContent : atom.displayContent
        editMode = true
    }
    private func commitEdit() {
        let buf = editBuffer
        editMode = false
        #if os(iOS) || os(visionOS)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
        if buf != atom.displayContent { store.updateRaw(id: atom.id, newContent: buf) }
    }
}


// MARK: - Detail Type Picker

/// Inline 6-dot type selector for manual override in AtomDetailView.
private struct DetailTypePicker: View {
    let current: AtomType
    let onSelect: (AtomType) -> Void

    var body: some View {
        HStack(spacing: NSpace.lg) {
            ForEach(AtomType.allCases, id: \.self) { type in
                Button {
                    guard type != current else { return }
                    onSelect(type)
                } label: {
                    VStack(spacing: 5) {
                        Circle()
                            .fill(type.phosphor.opacity(type == current ? 1.0 : 0.18))
                            .frame(width: 8, height: 8)
                            .shadow(color: type == current ? type.phosphor.opacity(0.7) : .clear, radius: 6)
                        Text(type.rawValue)
                            .font(NFont.mono(8))
                            .foregroundStyle(type == current
                                             ? type.phosphor.opacity(0.75)
                                             : NSColorToken.textGhostDim)
                            .tracking(0.8)
                    }
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(type == current ? "\(type.label), selected" : type.label)
                .accessibilityHint(type == current ? "" : "Double-tap to change type to \(type.label)")
            }
        }
        .padding(.vertical, NSpace.xs)
    }
}

/// Minimal flow layout — wraps children left-to-right, breaks into new rows as needed.
private struct TagFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = computeRows(maxWidth: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.reduce(0.0) { acc, row in
            acc + (row.map { subviews[$0].sizeThatFits(.unspecified).height }.max() ?? 0) + spacing
        } - spacing
        return CGSize(width: proposal.width ?? 0, height: max(0, height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(maxWidth: bounds.width, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            let rowHeight = row.map { subviews[$0].sizeThatFits(.unspecified).height }.max() ?? 0
            for idx in row {
                let size = subviews[idx].sizeThatFits(.unspecified)
                subviews[idx].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += rowHeight + spacing
        }
    }

    private func computeRows(maxWidth: CGFloat, subviews: Subviews) -> [[Int]] {
        var rows: [[Int]] = [[]]
        var rowWidth: CGFloat = 0
        for (i, subview) in subviews.enumerated() {
            let w = subview.sizeThatFits(.unspecified).width
            if !rows[rows.count - 1].isEmpty && rowWidth + spacing + w > maxWidth {
                rows.append([])
                rowWidth = 0
            }
            rows[rows.count - 1].append(i)
            rowWidth += (rows[rows.count - 1].count > 1 ? spacing : 0) + w
        }
        return rows.filter { !$0.isEmpty }
    }
}
