#if os(macOS)
import Foundation
import AVFoundation
import Observation

// ─── GeminiLiveTranscriber ────────────────────────────────────────────────────
//
// Real-time meeting transcription via Gemini Live API (WebSocket).
// Model: gemini-3.1-flash-live-preview
//
// Protocol:
//   1. Open WebSocket to Gemini Live endpoint
//   2. Send BidiGenerateContentSetup with system prompt + input_audio_transcription
//   3. Stream raw PCM16 @ 16 kHz mono in realtime_input messages
//   4. Receive serverContent.inputTranscription chunks — accumulate and surface
//
// Speaker attribution:
//   The audio stream is a mix of mic (user) and system audio (call participants).
//   The system prompt instructs Gemini to identify distinct voices and label them
//   "You:" (loudest / closest mic pattern) vs "Speaker 1:", "Speaker 2:", etc.
//   Gemini 3.1 Flash Live has acoustic nuance detection designed for exactly this.
//
// Threading:
//   sendAudio() can be called from any queue — it dispatches to an internal serial
//   queue. onUpdate fires on @MainActor.

@MainActor
@Observable
final class GeminiLiveTranscriber {
    private(set) var transcript: String = ""
    private(set) var isConnected: Bool  = false
    var onUpdate: @MainActor (String) -> Void = { _ in }

    private let apiKey: String
    private var wsTask: URLSessionWebSocketTask?
    private let sendQueue = DispatchQueue(label: "com.nous.gemini-live.send", qos: .userInteractive)

    // Resampling: any source rate/format → 16 kHz int16 mono
    // Lazy cache: keyed on source format description so mic (44.1kHz float32) and
    // system audio (16kHz float32 from SCStream bridge) both get correct converters.
    private var converterCache: [String: AVAudioConverter] = [:]
    private var targetFormat: AVAudioFormat?

    init(apiKey: String = AppEnv.geminiAPIKey) {
        self.apiKey = apiKey
    }

    // MARK: – Connect

    /// `attendees` — comma-separated participant names ("John, Sarah, Alex").
    /// When provided, Gemini maps detected voices to these names by listening
    /// for introductions ("Hi I'm Sarah"), direct address ("Thanks John"),
    /// and first-speaker heuristics.
    func connect(inputFormat: AVAudioFormat, attendees: String = "") async throws {
        guard !apiKey.isEmpty else {
            throw NSError(domain: "GeminiLive", code: -99,
                          userInfo: [NSLocalizedDescriptionKey: "NOUS_GEMINI_API_KEY not set"])
        }

        // Build target format: 16kHz int16 mono (Gemini Live requirement)
        let fmt = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                sampleRate: 16_000,
                                channels: 1,
                                interleaved: true)!
        targetFormat = fmt
        // Pre-warm converter for the primary mic format
        if let conv = AVAudioConverter(from: inputFormat, to: fmt) {
            converterCache[inputFormat.cacheKey] = conv
        }

        // Open WebSocket
        let urlStr = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=\(apiKey)"
        guard let url = URL(string: urlStr) else {
            throw NSError(domain: "GeminiLive", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid WebSocket URL"])
        }
        let session  = URLSession(configuration: .default)
        let task     = session.webSocketTask(with: url)
        wsTask       = task
        task.resume()

        // Build attendee-aware system prompt
        let prompt = Self.buildSystemPrompt(attendees: attendees)

        // Send setup.
        // Wire format confirmed by testing against v1beta endpoint:
        // - Outer key: "setup" (proto field name, not "config" which is SDK abstraction)
        // - responseModalities: ["AUDIO"] — Live API does NOT support TEXT output modality
        //   (TEXT causes 1011 internal error); use AUDIO + inputAudioTranscription instead
        // - inputAudioTranscription: {} at setup level → server returns
        //   serverContent.inputTranscription.text for each speech segment
        let setup: [String: Any] = [
            "setup": [
                "model": "models/gemini-3.1-flash-live-preview",
                "generationConfig": [
                    "responseModalities": ["AUDIO"]
                ],
                // Transcribe incoming audio → serverContent.inputTranscription.text
                "inputAudioTranscription": [:],
                "systemInstruction": [
                    "parts": [["text": prompt]]
                ]
            ]
        ]
        let setupData = try JSONSerialization.data(withJSONObject: setup)
        try await task.send(.data(setupData))

        // Await setup confirmation (first server message)
        _ = try await task.receive()
        isConnected = true
        NousLogger.info("gemini-live", "connected, starting receive loop")

        startReceiveLoop(task: task)
    }

    // MARK: – Send audio

    /// Call from any thread. Converts any PCM buffer to 16kHz int16 and sends.
    /// Handles both mic (e.g. 44.1kHz float32) and system audio (16kHz float32
    /// from SCStreamAudioBridge) via a per-source-format converter cache.
    func send(_ buffer: AVAudioPCMBuffer) {
        guard isConnected, let task = wsTask,
              let targetFormat else { return }

        let srcFormat = buffer.format
        // Resolve or create converter for this source format
        let converter: AVAudioConverter
        if let cached = converterCache[srcFormat.cacheKey] {
            converter = cached
        } else if let fresh = AVAudioConverter(from: srcFormat, to: targetFormat) {
            converterCache[srcFormat.cacheKey] = fresh
            converter = fresh
        } else {
            return  // Incompatible format — skip
        }

        let inputFrames  = buffer.frameLength
        let ratio        = targetFormat.sampleRate / srcFormat.sampleRate
        let outputFrames = AVAudioFrameCount(Double(inputFrames) * ratio) + 1
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrames) else { return }

        var convErr: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, status in
            status.pointee = .haveData
            return buffer
        }
        let status = converter.convert(to: outBuf, error: &convErr, withInputFrom: inputBlock)
        guard status != .error, convErr == nil, outBuf.frameLength > 0 else { return }

        guard let int16Ptr = outBuf.int16ChannelData?[0] else { return }
        let pcmData = Data(bytes: int16Ptr, count: Int(outBuf.frameLength) * 2)

        // Capture wsTask on MainActor before crossing to background queue
        let capturedTask = task
        sendQueue.async {
            // Correct wire format per Live API docs:
            // realtimeInput.audio.{data, mimeType} — NOT mediaChunks
            let msg: [String: Any] = [
                "realtimeInput": [
                    "audio": [
                        "data":     pcmData.base64EncodedString(),
                        "mimeType": "audio/pcm;rate=16000"
                    ]
                ]
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: msg) else { return }
            capturedTask.send(.data(data)) { _ in }
        }
    }

    // MARK: – Disconnect

    func disconnect() {
        wsTask?.cancel(with: .normalClosure, reason: nil)
        wsTask         = nil
        isConnected    = false
        converterCache = [:]
        targetFormat   = nil
    }

    // MARK: – Receive loop

    private func startReceiveLoop(task: URLSessionWebSocketTask) {
        Task { @MainActor [weak self] in
            while let self, self.wsTask != nil {
                do {
                    let message = try await task.receive()
                    self.handleMessage(message)
                } catch {
                    // WebSocket closed or error — stop loop
                    self.isConnected = false
                    break
                }
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        var data: Data?
        switch message {
        case .data(let d):   data = d
        case .string(let s): data = s.data(using: .utf8)
        @unknown default:    return
        }
        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        // BidiGenerateContentServerContent → inputTranscription.text
        if let serverContent = json["serverContent"] as? [String: Any] {
            if let inputTx = serverContent["inputTranscription"] as? [String: Any],
               let text = inputTx["text"] as? String, !text.trimmingCharacters(in: .whitespaces).isEmpty {
                transcript += (transcript.isEmpty ? "" : "\n") + text.trimmingCharacters(in: .whitespaces)
                onUpdate(transcript)
            }
            // Also handle model-turn text in case transcription comes via regular output
            if let modelTurn = serverContent["modelTurn"] as? [String: Any],
               let parts = modelTurn["parts"] as? [[String: Any]] {
                let text = parts.compactMap { $0["text"] as? String }.joined()
                if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                    transcript += (transcript.isEmpty ? "" : "\n") + text.trimmingCharacters(in: .whitespaces)
                    onUpdate(transcript)
                }
            }
        }
    }

    // MARK: – System prompt

    static func buildSystemPrompt(attendees: String) -> String {
        let names = attendees
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let exampleName = names.first ?? "Speaker 1"

        var speakerRules: String
        if names.isEmpty {
            speakerRules = """
            - All other distinct voices → label "Speaker 1:", "Speaker 2:", "Speaker 3:", etc.
              Assign numbers in order of first appearance. Keep labels consistent throughout.
            """
        } else {
            let roster = names.joined(separator: ", ")
            speakerRules = """
            - The other participants in this meeting are: \(roster)
              Identify each person's voice and use their real name as the label (e.g. "\(names[0]):").
              Match voices to names by listening for:
                • Self-introduction: "Hi, I'm \(names[0])" or "This is \(names[0])"
                • Direct address: "Thanks \(names[0])" or "What do you think, \(names[0])?"
                • Speaker order heuristics (first non-You voice is often the meeting host)
              If a voice cannot be confidently matched to a name, use "Speaker N:" as fallback.
              Once matched, use that name for ALL future utterances from that voice.
            """
        }

        return """
        You are transcribing a live meeting in real-time.
        Identify distinct speakers by voice characteristics and label them consistently.

        Labeling rules:
        - The primary microphone input (clearest / closest voice, loudest) → always label "You:"
        \(speakerRules)

        Format — one utterance per line, label first:
        You: We should ship the freemium tier by Q2.
        \(exampleName): Agreed — what's the biggest risk?
        You: Probably the onboarding flow, we haven't tested at scale.

        Output transcript lines only. No headers, timestamps, or preamble.
        Continue without repeating previously output text.
        """
    }
}

// MARK: – AVAudioFormat cache key

private extension AVAudioFormat {
    /// Stable string key for converter caching: "rate_channels_format"
    var cacheKey: String {
        "\(sampleRate)_\(channelCount)_\(commonFormat.rawValue)"
    }
}

#endif
