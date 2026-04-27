#if os(macOS)
import SwiftUI

// ─── MacAtomDetail ────────────────────────────────────────────────────────────
//
// Right column: full atom detail with inline editing.
//
// Layout:
//   ┌─ toolbar row: type dot · // type · timestamp · spacer · [raw] [edit] [delete]
//   ├─ phosphor backdrop (same radial as iOS)
//   ├─ scrolling content body
//   │   ├─ content (markdown / editor)
//   │   ├─ tags section
//   │   └─ mode footer (// raw / // refined / // refining...)
//   └─ related strip (bottom, horizontal scroll)

struct MacAtomDetail: View {
    let atom: AtomSnapshot
    let related: [AtomSnapshot]
    let store: AtomStore
    let onClose: () -> Void
    var onDelete: ((AtomSnapshot) -> Void)? = nil
    var onPickRelated: ((AtomSnapshot) -> Void)? = nil

    @State private var editMode  = false
    @State private var editBuffer = ""
    @State private var showRaw   = false
    @FocusState private var editorFocus: Bool

    var body: some View {
        ZStack {
            backdrop

            VStack(spacing: 0) {
                headerBar
                    .padding(.horizontal, NSpace.xl)
                    .padding(.top, NSpace.md)
                    .padding(.bottom, NSpace.sm)

                Divider()
                    .overlay(atom.type.phosphor.opacity(0.20))

                contentScroll

                if !related.isEmpty {
                    relatedStrip
                }
            }
        }
        .background(NSColorToken.inkVoid)
        .onAppear { editBuffer = atom.displayContent }
        .onChange(of: atom.id) { _, _ in
            editMode   = false
            editBuffer = atom.displayContent
        }
    }

    // MARK: – Backdrop

    private var backdrop: some View {
        ZStack {
            RadialGradient(
                colors: [atom.type.phosphor.opacity(0.18), .clear],
                center: UnitPoint(x: 0.15, y: 0.08),
                startRadius: 0,
                endRadius: 480
            )
            RadialGradient(
                colors: [atom.type.phosphor.opacity(0.06), .clear],
                center: UnitPoint(x: 0.85, y: 1.0),
                startRadius: 0,
                endRadius: 320
            )
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .animation(.spring(response: 0.6, dampingFraction: 0.7), value: atom.type)
    }

    // MARK: – Header bar

    private var headerBar: some View {
        HStack(alignment: .center, spacing: NSpace.md) {
            // Type dot + label
            HStack(spacing: NSpace.sm) {
                AtomDot(type: atom.type)
                Text("// \(atom.type.rawValue)")
                    .font(NFont.mono(11))
                    .foregroundStyle(atom.type.phosphor.opacity(0.75))
            }

            Text(atom.createdAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                .font(NFont.mono(10))
                .foregroundStyle(NSColorToken.textGhost)
                .monospacedDigit()

            Spacer(minLength: 0)

            // Controls
            HStack(spacing: NSpace.sm) {
                // Raw / refined toggle
                if atom.refinedContent != nil {
                    Button {
                        withAnimation(.nEaseOutQuint) { showRaw.toggle() }
                    } label: {
                        Text(showRaw ? "// raw" : "// refined")
                            .font(NFont.mono(10))
                            .foregroundStyle(NSColorToken.textGhost)
                    }
                    .buttonStyle(.plain)
                    .help(showRaw ? "Show refined version" : "Show raw capture")
                }

                // Edit
                Button {
                    if editMode {
                        commitEdit()
                    } else {
                        editBuffer = atom.displayContent
                        editMode = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            editorFocus = true
                        }
                    }
                } label: {
                    Text(editMode ? "// save" : "// edit")
                        .font(NFont.mono(10))
                        .foregroundStyle(editMode
                            ? atom.type.phosphor
                            : NSColorToken.textGhost)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("e", modifiers: .command)
                .help(editMode ? "Save (⌘S)" : "Edit (⌘E)")

                if editMode {
                    Button {
                        editMode   = false
                        editBuffer = atom.displayContent
                    } label: {
                        Text("// cancel")
                            .font(NFont.mono(10))
                            .foregroundStyle(NSColorToken.textGhost)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.escape, modifiers: [])
                }

                // Delete
                if !editMode {
                    Button {
                        onDelete?(atom)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundStyle(NSColorToken.textGhost)
                    }
                    .buttonStyle(.plain)
                    .help("Delete atom (⌘⌫)")
                }
            }
        }
    }

    // MARK: – Content scroll

    private var contentScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NSpace.xl) {
                // Body
                if editMode {
                    TextEditor(text: $editBuffer)
                        .font(NFont.detailBody(15))
                        .foregroundStyle(NSColorToken.textPrimary)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 200)
                        .focused($editorFocus)
                        .onSubmit { commitEdit() }
                } else {
                    let content = showRaw ? atom.rawContent : atom.displayContent
                    MarkdownView(
                        raw: content,
                        store: store,
                        atomID: atom.id,
                        linkColor: atom.type.phosphor,
                        onPickAtom: { a in onPickRelated?(a) }
                    )
                        .font(NFont.detailBody(15))
                        .foregroundStyle(NSColorToken.textPrimary)
                        .textSelection(.enabled)
                }

                // Tags
                if !atom.tags.isEmpty || editMode {
                    VStack(alignment: .leading, spacing: NSpace.sm) {
                        Text("// tags")
                            .font(NFont.mono(10))
                            .foregroundStyle(NSColorToken.textGhost)
                        TagFlow {
                            ForEach(atom.tags, id: \.self) { tag in
                                TagChip(value: tag.value,
                                        phosphor: atom.type.phosphor)
                            }
                        }
                    }
                }

                // Mode footer
                modeFooter
            }
            .padding(.horizontal, NSpace.xl)
            .padding(.vertical, NSpace.lg)
        }
    }

    // MARK: – Mode footer

    private var modeFooter: some View {
        HStack(spacing: NSpace.xs) {
            if atom.isRefining {
                Circle()
                    .fill(NSColorToken.Phos.amber)
                    .frame(width: 4, height: 4)
                Text("// refining...")
                    .font(NFont.mono(10))
                    .foregroundStyle(NSColorToken.Phos.amber.opacity(0.65))
            } else if atom.refinedContent != nil {
                Circle()
                    .fill(atom.type.phosphor.opacity(0.50))
                    .frame(width: 4, height: 4)
                Text(showRaw ? "// raw" : "// refined")
                    .font(NFont.mono(10))
                    .foregroundStyle(NSColorToken.textGhost.opacity(0.55))
            } else {
                Circle()
                    .fill(NSColorToken.textGhost.opacity(0.30))
                    .frame(width: 4, height: 4)
                Text("// raw")
                    .font(NFont.mono(10))
                    .foregroundStyle(NSColorToken.textGhost.opacity(0.40))
            }
        }
    }

    // MARK: – Related strip

    private var relatedStrip: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(NSColorToken.textGhost.opacity(0.10))
                .frame(height: 0.5)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: NSpace.md) {
                    Text("// related")
                        .font(NFont.mono(10))
                        .foregroundStyle(NSColorToken.textGhost)
                        .padding(.trailing, NSpace.xs)

                    ForEach(related) { rel in
                        relatedChip(rel)
                    }
                }
                .padding(.horizontal, NSpace.xl)
                .padding(.vertical, NSpace.md)
            }
        }
        .background(NSColorToken.inkPaper.opacity(0.60))
    }

    private func relatedChip(_ rel: AtomSnapshot) -> some View {
        Button {
            onPickRelated?(rel)
        } label: {
            HStack(spacing: NSpace.xs) {
                Circle()
                    .fill(rel.type.phosphor)
                    .frame(width: 5, height: 5)
                Text(rel.oneLiner)
                    .font(NFont.mono(11))
                    .foregroundStyle(NSColorToken.textSecondary)
                    .lineLimit(1)
                    .frame(maxWidth: 180)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, NSpace.sm)
            .padding(.vertical, NSpace.xs)
            .background(NSColorToken.inkRaised)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(rel.type.phosphor.opacity(0.20), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: – Edit helpers

    private func commitEdit() {
        let trimmed = editBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != atom.displayContent else {
            editMode = false
            return
        }
        store.updateRaw(id: atom.id, newContent: trimmed)
        editMode = false
        NousLogger.info("mac", "atom edited", ["id": atom.id.uuidString])
    }
}

#endif
