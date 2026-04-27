import SwiftUI

/// Specimen slab. Full-screen surface for one atom.
/// Layout: floating controls (top-right) → scrolling content (type block → body → footer → tags) → related strip (pinned).
/// Type identity lives inside the scroll, not a header bar — creates editorial breathing room.
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
                // Floating controls — don't interrupt the reading surface
                controls
                    .padding(.horizontal, NSpace.xl)
                    .padding(.top, NSpace.lg)

                contentScroll

                if !related.isEmpty {
                    relatedDock
                }
            }
        }
        .background(NSColorToken.inkVoid.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .transition(.opacity)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                refinePulse = true
            }
        }
    }

    // MARK: – Backdrop

    private var backdrop: some View {
        ZStack {
            RadialGradient(
                colors: [atom.type.phosphor.opacity(0.30), .clear],
                center: UnitPoint(x: 0.12, y: 0.10),
                startRadius: 0,
                endRadius: 600
            )
            RadialGradient(
                colors: [atom.type.phosphor.opacity(0.07), .clear],
                center: UnitPoint(x: 0.90, y: 1.0),
                startRadius: 0,
                endRadius: 380
            )
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        // Cross-fades the halo color when type is revealed by Gemini
        .animation(.spring(response: 0.6, dampingFraction: 0.7), value: atom.type)
    }

    // MARK: – Controls (floating, top-right)

    private var controls: some View {
        HStack(spacing: NSpace.xs) {
            Spacer(minLength: 0)
            if editMode {
                Button(action: commitEdit) {
                    Text("done")
                        .font(NFont.mono(11))
                        .foregroundStyle(atom.type.phosphor.opacity(0.80))
                        .frame(height: 40)
                        .padding(.horizontal, NSpace.sm)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Button(action: deleteAtom) {
                    Image(systemName: "trash")
                        .font(.system(size: 12, weight: .light))
                        .foregroundStyle(NSColorToken.textGhost)
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Button(action: close) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 14, weight: .light))
                    .foregroundStyle(NSColorToken.textSecondary)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: – Content scroll

    private var contentScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                typeBlock
                    .padding(.horizontal, NSpace.xl)
                    .padding(.top, NSpace.xxxl)
                    .padding(.bottom, NSpace.x4)

                bodyContent
                    .padding(.horizontal, NSpace.xl)

                statusLine
                    .padding(.horizontal, NSpace.xl)
                    .padding(.top, NSpace.lg)

                tagBlock
                    .padding(.horizontal, NSpace.xl)
                    .padding(.top, NSpace.xxl)

                Color.clear.frame(height: NSpace.x5)
            }
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: – Type block (identity header inside scroll)

    private var typeBlock: some View {
        VStack(alignment: .leading, spacing: NSpace.sm) {
            HStack(alignment: .center, spacing: NSpace.sm) {
                AtomDot(type: atom.type, size: 11)
                // Refining pulse dot — appears alongside the main dot while processing
                if atom.isRefining {
                    Circle()
                        .fill(atom.type.phosphor)
                        .frame(width: 3, height: 3)
                        .opacity(refinePulse ? 0.85 : 0.15)
                }
            }
            // Tap type label → open inline picker for manual override
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
                                ? atom.type.phosphor.opacity(refinePulse ? 0.65 : 0.30)
                                : atom.type.phosphor.opacity(0.55)
                        )
                        .textCase(.uppercase)
                        .tracking(2.8)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 1.8).repeatForever(autoreverses: true), value: refinePulse)
                        .contentTransition(.opacity)
                        .animation(.nEaseOutQuint, value: atom.type)
                    if !atom.isRefining {
                        Image(systemName: showTypePicker ? "chevron.up" : "chevron.down")
                            .font(.system(size: 8, weight: .light))
                            .foregroundStyle(atom.type.phosphor.opacity(0.35))
                    }
                }
            }
            .buttonStyle(.plain)

            // Inline type picker — 6 dots, single tap to change
            if showTypePicker {
                DetailTypePicker(current: atom.type) { newType in
                    store.setType(id: atom.id, to: newType)
                    withAnimation(.nEaseOutQuint) { showTypePicker = false }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .topLeading)))
                .padding(.top, NSpace.xs)
            }

            Text(createdString)
                .font(NFont.mono(10))
                .foregroundStyle(NSColorToken.textGhost)
                .monospacedDigit()
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
                .lineSpacing(6)
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
                            .fill(atom.type.phosphor.opacity(0.20))
                            .frame(height: 1.5)
                            .blur(radius: 2.5)
                            .offset(y: geo.size.height * max(0, scanlineY))
                            .animation(
                                reduceMotion ? nil : .linear(duration: 1.4).repeatForever(autoreverses: false),
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
                // Blur-swap-unblur crossfade when refined content arrives
                withAnimation(.nEaseOutQuint) { contentBlur = 3 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                    withAnimation(.nEaseOutQuint) { contentBlur = 0 }
                }
            }
        }
    }

    // MARK: – Status line

    private var statusLine: some View {
        HStack(spacing: NSpace.md) {
            Group {
                if atom.isRefining {
                    // Atmospheric refining indicator — pulsing text, not just a spinner
                    HStack(spacing: 5) {
                        Text("//")
                            .foregroundStyle(atom.type.phosphor.opacity(0.35))
                        Text("refining")
                            .foregroundStyle(atom.type.phosphor.opacity(refinePulse ? 0.75 : 0.25))
                            .animation(reduceMotion ? nil : .easeInOut(duration: 1.8).repeatForever(autoreverses: true), value: refinePulse)
                    }
                    .font(NFont.mono(10))
                } else if atom.refinedContent != nil {
                    HStack(spacing: 5) {
                        Text("//")
                            .foregroundStyle(NSColorToken.textGhost.opacity(0.45))
                        Text(showRaw ? "raw" : "refined")
                            .foregroundStyle(NSColorToken.textGhost)
                        Text("· hold to toggle")
                            .foregroundStyle(NSColorToken.textGhost.opacity(0.35))
                    }
                    .font(NFont.mono(10))
                }
            }
            Spacer(minLength: 0)
            if atom.type == .task {
                taskToggle
            }
        }
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
        }
        .buttonStyle(.plain)
    }

    // MARK: – Tag block

    private var tagBlock: some View {
        VStack(alignment: .leading, spacing: NSpace.sm) {
            // Section marker
            HStack(spacing: NSpace.sm) {
                Rectangle()
                    .fill(NSColorToken.textGhost.opacity(0.18))
                    .frame(width: 16, height: 0.5)
                Text("tags")
                    .font(NFont.mono(9))
                    .foregroundStyle(NSColorToken.textGhost.opacity(0.55))
                    .tracking(1.8)
                    .textCase(.uppercase)
            }

            // Existing tags with remove buttons
            if !atom.tags.isEmpty {
                TagFlowLayout(spacing: NSpace.sm) {
                    ForEach(atom.tags, id: \.self) { tag in
                        HStack(spacing: 4) {
                            Text(tag.value)
                                .font(NFont.monoSmall(10))
                                .foregroundStyle(NSColorToken.textSecondary)
                                .textCase(.uppercase)
                                .tracking(1.2)
                            Button(action: { store.removeTag(id: atom.id, tag: tag.value) }) {
                                Image(systemName: "xmark")
                                    .font(.system(size: 7, weight: .medium))
                                    .foregroundStyle(NSColorToken.textGhost)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, NSpace.sm)
                        .padding(.vertical, 5)
                        .overlay(
                            RoundedRectangle(cornerRadius: 2)
                                .stroke(NSColorToken.textGhost.opacity(0.45), lineWidth: 0.5)
                        )
                    }
                }
            }

            // Add tag control
            if addingTag {
                HStack(spacing: NSpace.sm) {
                    TextField("", text: $tagInput, prompt: Text("tag name").foregroundColor(NSColorToken.textGhost))
                        .font(NFont.monoSmall(11))
                        .foregroundStyle(NSColorToken.textPrimary)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onSubmit { commitTag() }
                        .padding(.horizontal, NSpace.sm)
                        .padding(.vertical, 5)
                        .overlay(
                            RoundedRectangle(cornerRadius: 2)
                                .stroke(atom.type.phosphor.opacity(0.4), lineWidth: 0.5)
                        )
                        .frame(minWidth: 90, maxWidth: 180)
                    Button(action: { addingTag = false; tagInput = "" }) {
                        Text("cancel")
                            .font(NFont.mono(9))
                            .foregroundStyle(NSColorToken.textGhost.opacity(0.6))
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
                    .foregroundStyle(NSColorToken.textGhost.opacity(0.5))
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
            // Section divider — ruled line with centered label
            HStack(spacing: NSpace.md) {
                Rectangle()
                    .fill(NSColorToken.textGhost.opacity(0.14))
                    .frame(height: 0.5)
                Text("nearby")
                    .font(NFont.mono(9))
                    .foregroundStyle(NSColorToken.textGhost.opacity(0.45))
                    .tracking(1.8)
                    .textCase(.uppercase)
                    .fixedSize()
                Rectangle()
                    .fill(NSColorToken.textGhost.opacity(0.06))
                    .frame(height: 0.5)
            }
            .padding(.horizontal, NSpace.xl)
            .padding(.vertical, NSpace.lg)

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
        // Subtle ink wash rises from bottom — dock reads as footer, not overlay
        .background(
            LinearGradient(
                colors: [
                    NSColorToken.inkPaper.opacity(0.0),
                    NSColorToken.inkPaper.opacity(0.65)
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
                        .foregroundStyle(NSColorToken.textGhost)
                        .textCase(.uppercase)
                        .tracking(1.2)
                }
                Text(r.oneLiner)
                    .font(NFont.body(13))
                    .foregroundStyle(NSColorToken.textSecondary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 176, alignment: .topLeading)
            .padding(NSpace.md)
            .background(NSColorToken.inkRaised.opacity(0.75))
            .overlay(
                Rectangle()
                    .stroke(NSColorToken.textGhost.opacity(0.10), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
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
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        if buf != atom.displayContent { store.updateRaw(id: atom.id, newContent: buf) }
    }
}


// MARK: - Detail Type Picker

/// Inline 6-dot type selector for manual override in AtomDetailView.
/// Current type shown with phosphor glow; others ghost. Tap to change.
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
                    VStack(spacing: 4) {
                        Circle()
                            .fill(type.phosphor.opacity(type == current ? 1.0 : 0.20))
                            .frame(width: 8, height: 8)
                            .shadow(color: type == current ? type.phosphor.opacity(0.6) : .clear, radius: 5)
                        Text(type.rawValue)
                            .font(NFont.mono(8))
                            .foregroundStyle(type == current
                                             ? type.phosphor.opacity(0.75)
                                             : NSColorToken.textGhost.opacity(0.45))
                            .tracking(0.8)
                    }
                }
                .buttonStyle(.plain)
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
