import Foundation
import Observation

/// Drives a synthesis session: question → SSE stream → progressive answer + citations.
/// Stream cancellable mid-flight (PRD §2.4 "user can interrupt/regenerate").
@Observable
@MainActor
final class SynthesisVM {

    // Axiom log contract — category: "synthesis"
    //   submit      q_len, user
    //   stage       stage (embed|retrieve|synthesize|streaming)
    //   done        citations, answer_len, elapsed_ms
    //   failed      error, elapsed_ms
    //   cancelled   elapsed_ms (0 if not yet started)

    enum Stage: Equatable {
        case idle
        case embedding
        case retrieving
        case synthesizing
        case streaming
        case done
        case failed(String)
    }

    struct Citation: Identifiable, Hashable {
        let id: UUID          // atomID
        let snippet: String   // already prefixed [N]
        let score: Double
    }

    var question: String = ""
    private(set) var stage: Stage = .idle
    private(set) var answer: String = ""
    private(set) var citations: [Citation] = []
    private(set) var stageDetail: String?

    var canSubmit: Bool {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count >= 2 && stage.isInteractive
    }
    var isStreaming: Bool {
        switch stage {
        case .embedding, .retrieving, .synthesizing, .streaming: return true
        default: return false
        }
    }

    private let backend: NousBackendClient
    private let userID: UUID
    private var task: Task<Void, Never>?
    private var submitTime: Date?

    init(backend: NousBackendClient, userID: UUID) {
        self.backend = backend
        self.userID = userID
    }

    func submit() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { return }
        cancel()
        answer = ""
        citations = []
        stageDetail = nil
        stage = .embedding
        submitTime = Date()

        NousLogger.info("synthesis", "submit", [
            "q_len": q.count,
            "user": userID.uuidString,
        ])

        task = Task { [weak self] in
            guard let self else { return }
            do {
                let stream = try await self.backend.synthesize(
                    userID: self.userID,
                    question: q,
                    contextLimit: 12
                )
                for try await ev in stream {
                    if Task.isCancelled { break }
                    self.handle(ev)
                }
                if !Task.isCancelled {
                    self.stage = .done
                    NousLogger.info("synthesis", "done", [
                        "citations": self.citations.count,
                        "answer_len": self.answer.count,
                        "elapsed_ms": self.elapsedMs,
                    ])
                }
            } catch {
                NousLogger.error("synthesis", "failed", [
                    "error": error.localizedDescription,
                    "elapsed_ms": self.elapsedMs,
                ])
                self.stage = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        let wasStreaming = isStreaming
        task?.cancel()
        task = nil
        if wasStreaming {
            NousLogger.info("synthesis", "cancelled", ["elapsed_ms": elapsedMs])
            stage = .idle
        }
    }

    func reset() {
        cancel()
        question = ""
        answer = ""
        citations = []
        stage = .idle
        stageDetail = nil
    }

    // MARK: - Event handling

    private func handle(_ ev: NousBackendClient.NousSSEEvent) {
        switch ev {
        case .update(let stageName, let detail):
            self.stageDetail = detail
            switch stageName {
            case "embed":
                self.stage = .embedding
                NousLogger.info("synthesis", "stage", ["stage": "embed"])
            case "retrieve":
                self.stage = .retrieving
                NousLogger.info("synthesis", "stage", ["stage": "retrieve"])
            case "synthesize":
                self.stage = .synthesizing
                NousLogger.info("synthesis", "stage", ["stage": "synthesize"])
            default:
                break
            }
        case .citation(let id, let snippet, let score):
            self.citations.append(Citation(id: id, snippet: snippet, score: score))
        case .token(let chunk):
            if self.stage != .streaming {
                self.stage = .streaming
                NousLogger.info("synthesis", "stage", [
                    "stage": "streaming",
                    "citations": self.citations.count,
                    "elapsed_ms": elapsedMs,
                ])
            }
            self.answer += chunk
        case .done:
            self.stage = .done
        }
    }

    // MARK: - Helpers

    private var elapsedMs: Int {
        guard let t = submitTime else { return 0 }
        return Int(Date().timeIntervalSince(t) * 1000)
    }
}

private extension SynthesisVM.Stage {
    var isInteractive: Bool {
        switch self {
        case .idle, .done, .failed: true
        default: false
        }
    }
}
