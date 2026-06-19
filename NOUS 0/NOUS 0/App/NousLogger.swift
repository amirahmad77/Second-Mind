import Foundation
import OSLog

// ─── NousLogger ──────────────────────────────────────────────────────────────
//
// Usage:
//   NousLogger.info("category", "message", ["key": "value"])
//   NousLogger.error("gemini", "refine failed", ["error": error.localizedDescription])
//
// Production: writes only to os.Logger (Console.app / log stream).
// Debug/Simulator: ALSO appends JSON lines to Documents/nous.logs.jsonl so
//   Claude Code can read them without Xcode.
//
// Claude Code quick-access (copy-paste into terminal):
//   tail -f "$(xcrun simctl get_app_container booted com.nous-core.NOUS-0 data)/Documents/nous.logs.jsonl" | python3 -m json.tool
//
// Or use the shell script at the project root: ./nous-logs

enum LogLevel: String, Sendable {
    case debug, info, warning, error, fault
}

enum NousLogger {
    // One os.Logger per subsystem. Categories bucket log noise for Console filtering.
    static let subsystem = "com.nous-core.NOUS-0"

    // Cached ISO8601 formatter — DateFormatter/ISO8601DateFormatter are expensive to init.
    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    // Platform tag injected into every Axiom entry.
    private static let platformTag: String = {
        #if os(macOS)
        return "macos"
        #elseif os(visionOS)
        return "visionos"
        #elseif os(iOS)
        return "ios"
        #else
        return "unknown"
        #endif
    }()

    private static var _loggers: [String: Logger] = [:]
    private static let loggerLock = NSLock()

    private static func osLogger(category: String) -> Logger {
        loggerLock.lock()
        defer { loggerLock.unlock() }
        if let existing = _loggers[category] { return existing }
        let l = Logger(subsystem: subsystem, category: category)
        _loggers[category] = l
        return l
    }

    // MARK: - Public API

    static func debug(_ category: String, _ message: String, _ meta: [String: Any] = [:]) {
        write(level: .debug, category: category, message: message, meta: meta)
    }
    static func info(_ category: String, _ message: String, _ meta: [String: Any] = [:]) {
        write(level: .info, category: category, message: message, meta: meta)
    }
    static func warning(_ category: String, _ message: String, _ meta: [String: Any] = [:]) {
        write(level: .warning, category: category, message: message, meta: meta)
    }
    static func error(_ category: String, _ message: String, _ meta: [String: Any] = [:]) {
        write(level: .error, category: category, message: message, meta: meta)
    }
    static func fault(_ category: String, _ message: String, _ meta: [String: Any] = [:]) {
        write(level: .fault, category: category, message: message, meta: meta)
    }

    // MARK: - Core

    private static func write(level: LogLevel, category: String, message: String, meta: [String: Any]) {
        let logger = osLogger(category: category)
        // NOTE: os.Logger fields below are marked `privacy: .public` so message +
        // meta are readable in Console.app / log stream on-device. This does NOT
        // expose them to any cloud service. PII/secret redaction for the
        // Axiom-bound payload happens in AxiomShipper.scrub(_:). Callers should
        // still avoid putting verbatim transcript/speech/PII into `meta`.
        let metaStr = meta.isEmpty ? "" : " \(meta)"
        switch level {
        case .debug:   logger.debug("\(message, privacy: .public)\(metaStr, privacy: .public)")
        case .info:    logger.info("\(message, privacy: .public)\(metaStr, privacy: .public)")
        case .warning: logger.warning("\(message, privacy: .public)\(metaStr, privacy: .public)")
        case .error:   logger.error("\(message, privacy: .public)\(metaStr, privacy: .public)")
        case .fault:   logger.fault("\(message, privacy: .public)\(metaStr, privacy: .public)")
        }
        // Build Axiom entry. _time field is required for correct time indexing.
        var entry: [String: Any] = [
            "_time":    iso8601.string(from: Date()),
            "level":    level.rawValue,
            "category": category,
            "message":  message,
            "platform": platformTag,
        ]
        for (k, v) in meta { entry[k] = v }
        AxiomShipper.shared.append(entry)
        #if DEBUG
        FileLogger.shared.append(level: level, category: category, message: message, meta: meta)
        #endif
    }
}

// ─── FileLogger (DEBUG only) ─────────────────────────────────────────────────
//
// Appends JSONL to Documents/nous.logs.jsonl. Rolling: trims to last 2000 lines
// when file exceeds 2 MB so the file stays readable without growing unbounded.
// Thread-safe via a dedicated serial DispatchQueue.

#if DEBUG
final class FileLogger: @unchecked Sendable {
    static let shared = FileLogger()

    private let queue = DispatchQueue(label: "com.nous.filelog", qos: .utility)
    private let fileURL: URL
    private var handle: FileHandle?
    private let maxBytes: Int = 2 * 1024 * 1024  // 2 MB trim threshold
    private let trimToLines: Int = 1500

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = docs.appendingPathComponent("nous.logs.jsonl")
        queue.async { [weak self] in self?.openHandle() }
    }

    private func openHandle() {
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: fileURL)
        handle?.seekToEndOfFile()
    }

    func append(level: LogLevel, category: String, message: String, meta: [String: Any]) {
        queue.async { [weak self] in
            guard let self else { return }
            var entry: [String: Any] = [
                "t": ISO8601DateFormatter().string(from: Date()),
                "lvl": level.rawValue,
                "cat": category,
                "msg": message,
            ]
            if !meta.isEmpty { entry["meta"] = meta }
            guard let json = try? JSONSerialization.data(withJSONObject: entry),
                  let line = String(data: json, encoding: .utf8)
            else { return }
            let bytes = (line + "\n").data(using: .utf8) ?? Data()
            self.handle?.write(bytes)
            self.maybeRotate()
        }
    }

    private func maybeRotate() {
        guard let size = try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int,
              size > maxBytes else { return }
        // Read all lines, keep last trimToLines.
        guard let raw = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: true)
        let kept = lines.suffix(trimToLines).joined(separator: "\n") + "\n"
        guard let data = kept.data(using: .utf8) else { return }
        // Rewrite file.
        handle?.closeFile()
        try? data.write(to: fileURL, options: .atomic)
        openHandle()
    }

    // Exposed for debug UI / export.
    func logFilePath() -> String { fileURL.path }
}
#endif
