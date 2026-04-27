import Foundation
import OSLog

// ─── AxiomShipper ────────────────────────────────────────────────────────────
//
// Ships batched log entries to Axiom (axiom.co) for centralized observability.
//
// Config (set via env vars / Info.plist / AppEnv pattern):
//   NOUS_AXIOM_TOKEN   — personal or ingest token from axiom.co/settings/tokens
//   NOUS_AXIOM_DATASET — target dataset name (default: "nous-ios")
//   NOUS_AXIOM_URL     — base URL (default: "https://api.axiom.co")
//
// Behaviour:
//   • Buffers entries in memory (max 200).
//   • Flushes automatically every 15 seconds OR when 30 entries accumulate.
//   • Fire-and-forget: never throws, never blocks callers.
//   • Disabled when NOUS_AXIOM_TOKEN is empty (dev builds without config).
//
// Claude Code: once the axiom-mcp server is configured in settings.json,
//   run /query in Claude to search logs across all devices.
//
// Usage:
//   AxiomShipper.shared.append(NousLogger.Entry(...))
//   // called automatically by NousLogger — no direct usage needed.

final class AxiomShipper: @unchecked Sendable {
    static let shared = AxiomShipper()

    private let queue = DispatchQueue(label: "com.nous.axiom", qos: .utility)
    private var buffer: [[String: Any]] = []
    private var flushTimer: DispatchSourceTimer?

    private let maxBuffer = 200
    private let autoFlushCount = 30
    private let flushIntervalSeconds: Double = 15

    // Configuration resolved once at init — avoids AppEnv calls on hot path.
    private let token: String
    private let dataset: String
    private let ingestURL: URL?
    private let session: URLSession

    private init() {
        token   = AppEnv.axiomToken
        dataset = AppEnv.axiomDataset
        let base = AppEnv.axiomURL.isEmpty ? "https://api.axiom.co" : AppEnv.axiomURL
        ingestURL = URL(string: "\(base)/v1/datasets/\(dataset)/ingest")
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest  = 10
        cfg.timeoutIntervalForResource = 20
        session = URLSession(configuration: cfg)
        guard !token.isEmpty else { return }
        startTimer()
    }

    // MARK: - Public

    func append(_ entry: [String: Any]) {
        guard !token.isEmpty else { return }
        queue.async { [weak self] in
            guard let self else { return }
            self.buffer.append(entry)
            if self.buffer.count >= self.autoFlushCount {
                self.flushNow()
            }
        }
    }

    func flushSync() {
        queue.sync { flushNow() }
    }

    // MARK: - Timer

    private func startTimer() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + flushIntervalSeconds, repeating: flushIntervalSeconds)
        t.setEventHandler { [weak self] in self?.flushNow() }
        t.resume()
        flushTimer = t
    }

    // MARK: - Flush (called on queue)

    private func flushNow() {
        guard !buffer.isEmpty, let url = ingestURL else { return }
        let batch = buffer
        buffer.removeAll(keepingCapacity: true)

        guard let body = try? JSONSerialization.data(withJSONObject: batch) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        // Fire and forget. Log failures to OSLog only (not to Axiom — avoid loops).
        let task = session.dataTask(with: req) { _, resp, err in
            if let err { Logger(subsystem: "com.nous-core.NOUS-0", category: "axiom").warning("flush error: \(err.localizedDescription, privacy: .public)") }
            let status = (resp as? HTTPURLResponse)?.statusCode
            if let s = status, s >= 300 { Logger(subsystem: "com.nous-core.NOUS-0", category: "axiom").warning("flush HTTP \(s, privacy: .public)") }
        }
        task.resume()
    }
}

// ─── AppEnv additions ────────────────────────────────────────────────────────

extension AppEnv {
    static var axiomToken: String {
        let v = string(for: "NOUS_AXIOM_TOKEN")
        return v.isEmpty ? Secrets.axiomToken : v
    }
    static var axiomDataset: String {
        let v = string(for: "NOUS_AXIOM_DATASET")
        return v.isEmpty ? Secrets.axiomDataset : v
    }
    static var axiomURL: String {
        let v = string(for: "NOUS_AXIOM_URL")
        return v.isEmpty ? Secrets.axiomURL : v
    }
}
