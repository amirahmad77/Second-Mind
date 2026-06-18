import Foundation

/// Pure, UI-free export utilities for atoms.
///
/// Two formats:
///   - **Markdown** — human-readable, front-matter-ish header (type · tags · created)
///     followed by the display content. Single atom or a concatenated vault.
///   - **JSON** — machine-readable, via a small Codable DTO. We don't force
///     `AtomSnapshot` to encode (it carries transient/`@MainActor` concerns); instead
///     we map to `AtomExportDTO` at the boundary.
///
/// All functions are `static` and take value-type `AtomSnapshot` inputs, so they're
/// safe to call from any isolation context.
enum AtomExport {

    // MARK: – Codable DTO

    /// Stable wire shape for JSON export. Decoupled from `AtomSnapshot` so the
    /// export schema can evolve independently of the in-memory read model.
    struct AtomExportDTO: Codable, Sendable {
        let id: String
        let type: String
        let tags: [String]
        let raw: String
        let refined: String?
        let createdAt: String   // ISO8601
        let dueAt: String?      // ISO8601
        let taskDone: Bool?

        init(_ atom: AtomSnapshot) {
            self.id = atom.id.uuidString
            self.type = atom.type.rawValue
            self.tags = atom.tags.map(\.value)
            self.raw = atom.rawContent
            self.refined = atom.refinedContent
            self.createdAt = AtomExport.iso.string(from: atom.createdAt)
            self.dueAt = atom.dueAt.map { AtomExport.iso.string(from: $0) }
            self.taskDone = atom.taskDone
        }
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    // MARK: – Markdown

    /// Single-atom Markdown: header block + content body.
    static func markdown(_ atom: AtomSnapshot) -> String {
        var lines: [String] = []
        lines.append("# \(headline(for: atom))")
        lines.append("")
        lines.append("- **type:** \(atom.type.rawValue)")
        if !atom.tags.isEmpty {
            lines.append("- **tags:** \(atom.tags.map { "#\($0.value)" }.joined(separator: " "))")
        }
        lines.append("- **created:** \(displayDate.string(from: atom.createdAt))")
        if let due = atom.dueAt {
            lines.append("- **due:** \(displayDate.string(from: due))")
        }
        if let done = atom.taskDone {
            lines.append("- **task:** \(done ? "done" : "open")")
        }
        lines.append("")
        lines.append(atom.displayContent)
        return lines.joined(separator: "\n")
    }

    /// Vault Markdown: each atom as its own section, separated by horizontal rules.
    static func markdown(_ atoms: [AtomSnapshot]) -> String {
        guard !atoms.isEmpty else { return "# NOUS export\n\n_No atoms._\n" }
        let body = atoms.map { markdown($0) }.joined(separator: "\n\n---\n\n")
        let header = "<!-- NOUS export · \(atoms.count) atoms · \(displayDate.string(from: Date())) -->\n\n"
        return header + body + "\n"
    }

    // MARK: – JSON

    /// Vault JSON: pretty-printed, sorted keys, ISO8601 dates. Returns empty
    /// `Data` only on the (practically impossible) encode failure, which is logged.
    static func json(_ atoms: [AtomSnapshot]) -> Data {
        let dtos = atoms.map(AtomExportDTO.init)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            return try encoder.encode(dtos)
        } catch {
            NousLogger.error("export", "json encode failed", ["error": error.localizedDescription])
            return Data()
        }
    }

    // MARK: – Temp file for sharing

    /// Write `contents` to a uniquely-named temp file and return its URL.
    /// Suitable as a `ShareLink` item. Returns `nil` (and logs) on write failure.
    static func temporaryFile(name: String, contents: Data) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try contents.write(to: url, options: .atomic)
            return url
        } catch {
            NousLogger.error("export", "temp file write failed", [
                "name": name,
                "error": error.localizedDescription
            ])
            return nil
        }
    }

    /// Convenience overload for text payloads (Markdown).
    static func temporaryFile(name: String, contents: String) -> URL? {
        temporaryFile(name: name, contents: Data(contents.utf8))
    }

    // MARK: – Filename helpers

    /// Safe, dated default filename stem for a single atom.
    static func fileStem(for atom: AtomSnapshot) -> String {
        let datePart = fileDate.string(from: atom.createdAt)
        let slug = slugify(headline(for: atom))
        return slug.isEmpty ? "nous-\(datePart)" : "nous-\(datePart)-\(slug)"
    }

    /// Dated default filename stem for the whole vault.
    static func vaultFileStem() -> String {
        "nous-vault-\(fileDate.string(from: Date()))"
    }

    // MARK: – Private helpers

    /// First non-empty line of the display content, trimmed for use as a heading.
    private static func headline(for atom: AtomSnapshot) -> String {
        let firstLine = atom.displayContent
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stripped = firstLine.replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespaces)
        guard !stripped.isEmpty else { return atom.type.rawValue }
        return String(stripped.prefix(80))
    }

    private static func slugify(_ s: String) -> String {
        let lowered = s.lowercased()
        let mapped = lowered.map { ch -> Character in
            (ch.isLetter || ch.isNumber) ? ch : "-"
        }
        let collapsed = String(mapped)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return String(collapsed.prefix(48))
    }

    private static let displayDate: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    private static let fileDate: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
