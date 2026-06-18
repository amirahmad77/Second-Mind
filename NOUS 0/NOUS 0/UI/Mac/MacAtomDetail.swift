#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers

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

                // Export — Markdown (default) or JSON, via NSSavePanel.
                if !editMode {
                    Menu {
                        Button("Markdown (.md)") { exportAtom(asJSON: false) }
                        Button("JSON (.json)")   { exportAtom(asJSON: true) }
                    } label: {
                        Text("// export")
                            .font(NFont.mono(10))
                            .foregroundStyle(NSColorToken.textGhost)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Export atom to disk")
                    .accessibilityLabel("Export atom")
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

                // Also-see suggestions
                let suggestions = store.linkSuggestions[atom.id] ?? []
                if !suggestions.isEmpty {
                    AlsoSeeStrip(atomID: atom.id, suggestions: suggestions, store: store)
                }

                // Linked-from (backlinks)
                let inbound = store.inboundAtoms(for: atom.id)
                if !inbound.isEmpty {
                    LinkedFromSection(inbound: inbound) { a in
                        onPickRelated?(a)
                    }
                }

                // Speaker relabeling — only for meeting atoms with unresolved "Speaker N:" labels
                if atom.type == .meeting, !atom.isRefining {
                    let content = atom.refinedContent ?? atom.rawContent
                    let unresolved = SpeakerRelabelPanel.unresolvedSpeakers(in: content)
                    if !unresolved.isEmpty {
                        SpeakerRelabelPanel(
                            speakers: unresolved,
                            onRename: { old, new in
                                let updated = content.replacingOccurrences(of: "\(old):", with: "\(new):")
                                store.updateRaw(id: atom.id, newContent: updated)
                            }
                        )
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

    // MARK: – Export

    private func exportAtom(asJSON: Bool) {
        let stem = AtomExport.fileStem(for: atom)
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        if asJSON {
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "\(stem).json"
        } else {
            panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
            panel.nameFieldStringValue = "\(stem).md"
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let data = asJSON
            ? AtomExport.json([atom])
            : Data(AtomExport.markdown(atom).utf8)
        do {
            try data.write(to: url, options: .atomic)
            NousLogger.info("export", "atom exported", [
                "id": atom.id.uuidString,
                "format": asJSON ? "json" : "markdown"
            ])
        } catch {
            NousLogger.error("export", "atom export failed", [
                "id": atom.id.uuidString,
                "error": error.localizedDescription
            ])
        }
    }
}

// MARK: – SpeakerRelabelPanel

/// Shown on meeting atoms that still have unresolved "Speaker N:" labels.
/// Each row: "Speaker 1" → editable name field → confirm replaces all occurrences.
struct SpeakerRelabelPanel: View {
    let speakers:  [String]          // e.g. ["Speaker 1", "Speaker 2"]
    let onRename:  (String, String) -> Void   // (old label, new name)

    @State private var names: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: NSpace.sm) {
            HStack(spacing: NSpace.xs) {
                Circle()
                    .fill(NSColorToken.Phos.amber.opacity(0.7))
                    .frame(width: 4, height: 4)
                Text("// identify speakers")
                    .font(NFont.mono(10))
                    .foregroundStyle(NSColorToken.textGhost)
            }
            VStack(spacing: NSpace.xs) {
                ForEach(speakers, id: \.self) { speaker in
                    HStack(spacing: NSpace.sm) {
                        Text("\(speaker):")
                            .font(NFont.mono(11))
                            .foregroundStyle(NSColorToken.textTertiary)
                            .frame(width: 80, alignment: .leading)
                        TextField("Enter name…", text: Binding(
                            get:  { names[speaker] ?? "" },
                            set:  { names[speaker] = $0 }
                        ))
                        .font(NFont.mono(11))
                        .foregroundStyle(NSColorToken.textPrimary)
                        .textFieldStyle(.plain)
                        .onSubmit { commitRename(speaker) }
                        .padding(.horizontal, NSpace.sm)
                        .padding(.vertical, NSpace.xs)
                        .background(NSColorToken.inkRaised)
                        .overlay(
                            Rectangle()
                                .stroke(NSColorToken.textGhost.opacity(0.15), lineWidth: 0.5)
                        )
                        // Confirm button
                        let name = names[speaker] ?? ""
                        if !name.trimmingCharacters(in: .whitespaces).isEmpty {
                            Button("// apply") { commitRename(speaker) }
                                .font(NFont.mono(10))
                                .foregroundStyle(NSColorToken.Phos.amber)
                                .buttonStyle(.plain)
                                .transition(.opacity)
                        }
                    }
                }
            }
        }
        .padding(NSpace.md)
        .background(NSColorToken.inkPaper.opacity(0.7))
        .overlay(
            Rectangle()
                .stroke(NSColorToken.Phos.amber.opacity(0.20), lineWidth: 0.5)
        )
        .animation(.nEaseOutQuint, value: names.keys.sorted())
    }

    private func commitRename(_ speaker: String) {
        let name = (names[speaker] ?? "").trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        onRename(speaker, name)
        names.removeValue(forKey: speaker)
    }

    /// Extract all "Speaker N" labels from transcript text.
    static func unresolvedSpeakers(in text: String) -> [String] {
        let pattern = #/(?m)^(Speaker \d+):\s/#
        var seen = [String: Int]()
        for match in text.matches(of: pattern) {
            let label = String(match.1)
            seen[label, default: 0] += 1
        }
        // Sort by speaker number so the list is ordered
        return seen.keys.sorted {
            let n1 = Int($0.split(separator: " ").last ?? "0") ?? 0
            let n2 = Int($1.split(separator: " ").last ?? "0") ?? 0
            return n1 < n2
        }
    }
}

#endif
