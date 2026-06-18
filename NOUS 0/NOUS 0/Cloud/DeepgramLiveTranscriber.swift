#if os(macOS)
import Foundation
import AVFoundation
import Observation

// ─── DeepgramLiveTranscriber ──────────────────────────────────────────────────
//
// Real-time meeting transcription via Deepgram Nova-3 WebSocket.
//
// Architecture — two separate WebSocket connections:
//   • micConn   — mic audio (local user). diarize=false.
//                 Every utterance → "You: <text>"
//   • sysConn   — system audio (remote call participants). diarize=true.
//                 Words grouped by speaker → "Sarah: <text>", "Speaker 1: <text>"
//
// Speaker naming:
//   Deepgram assigns speaker indices (0, 1, 2…) in order of first appearance.
//   If attendee names are provided, they are mapped in that same order.
//   Otherwise falls back to "Speaker 1:", "Speaker 2:", etc.
//
// Transcript:
//   Segments are inserted in order of their `start` timestamp so mic and
//   system audio interleave naturally even if they arrive out of order.
//
// Threading:
//   sendMic() / sendSystem() safe to call from any thread.
//   onUpdate fires on @MainActor.

@MainActor
@Observable
final class DeepgramLiveTranscriber {
    private(set) var transcript: String = ""
    private(set) var isConnected: Bool  = false
    var onUpdate: @MainActor (String) -> Void = { _ in }

    // ── Internal segment model ──────────────────────────────────────────────
    private struct Segment {
        let start: Double
        let label: String   // "You", "Sarah", "Speaker 1", …
        let text:  String
    }
    private var segments: [Segment] = []

    // ── Speaker naming ──────────────────────────────────────────────────────
    private var attendeeNames:  [String]   = []
    private var speakerToName:  [Int: String] = [:]

    // ── Connections ─────────────────────────────────────────────────────────
    private let apiKey:  String

    /// Set by MacMeetingRecorder. Given a segment start offset (seconds from stream
    /// start), returns the speaker name from the Meet DOM active speaker timeline.
    /// Called on @MainActor in handleMessage — no isolation issues.
    var bridgeSpeakerAt: ((TimeInterval) -> String?)?

    /// Absolute date when connect() was called — used to convert Deepgram
    /// relative offsets to TimeIntervals for bridgeSpeakerAt lookups.
    private var streamStartDate: Date?

    // Off-MainActor send engine — owns conversion + WebSocket writes.
    // Audio tap callbacks call into this directly without any Task dispatch.
    private let engine = DeepgramSendEngine()

    init(apiKey: String = AppEnv.deepgramAPIKey) {
        self.apiKey = apiKey
    }

    /// Resolved key: prefers RemoteConfig (Supabase) over compile-time value.
    private var resolvedKey: String {
        let remote = RemoteConfig.shared.deepgramAPIKey
        return remote.isEmpty ? apiKey : remote
    }

    // MARK: – Connect

    /// `attendees` — comma-separated participant names ("John, Sarah, Alex").
    /// Mapped to diarized speaker indices in order of first appearance.
    func connect(inputFormat: AVAudioFormat, attendees: String = "") async throws {
        guard !resolvedKey.isEmpty else {
            throw NSError(domain: "Deepgram", code: -99,
                          userInfo: [NSLocalizedDescriptionKey:
                            "Deepgram API key not set — add NOUS_DEEPGRAM_API_KEY to LocalSecrets.xcconfig"])
        }

        attendeeNames   = attendees
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        speakerToName   = [:]
        segments        = []
        transcript      = ""
        streamStartDate = Date()

        // Open two connections in parallel
        async let mic = openConnection(diarize: false)
        async let sys = openConnection(diarize: true)
        let micTask = try await mic
        let sysTask = try await sys

        // Hand tasks + pre-warmed converter to the send engine (background)
        engine.configure(micTask: micTask, sysTask: sysTask,
                         micFormat: inputFormat)

        isConnected = true
        NousLogger.info("deepgram", "connected — mic + system audio")

        startReceiveLoop(task: micTask, isMic: true)
        startReceiveLoop(task: sysTask, isMic: false)
    }

    private func openConnection(diarize: Bool) async throws -> URLSessionWebSocketTask {
        var comps = URLComponents(string: "wss://api.deepgram.com/v1/listen")!
        comps.queryItems = [
            URLQueryItem(name: "model",            value: "nova-3"),
            URLQueryItem(name: "language",         value: "en"),
            URLQueryItem(name: "encoding",         value: "linear16"),
            URLQueryItem(name: "sample_rate",      value: "16000"),
            URLQueryItem(name: "channels",         value: "1"),
            URLQueryItem(name: "punctuate",        value: "true"),
            URLQueryItem(name: "smart_format",     value: "true"),
            URLQueryItem(name: "interim_results",  value: "false"),
            URLQueryItem(name: "endpointing",      value: "300"),
            URLQueryItem(name: "diarize",          value: diarize ? "true" : "false"),
        ]

        guard let url = comps.url else {
            throw NSError(domain: "Deepgram", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid Deepgram URL"])
        }

        var req = URLRequest(url: url)
        req.setValue("Token \(resolvedKey)", forHTTPHeaderField: "Authorization")

        let task = URLSession.shared.webSocketTask(with: req)
        task.resume()
        return task
    }

    // MARK: – Send audio (call from any thread — no MainActor needed)

    /// Mic audio — called directly from AVAudioEngine tap callback thread.
    nonisolated func sendMic(_ buffer: AVAudioPCMBuffer) {
        engine.send(buffer, isMic: true)
    }

    /// System audio — called directly from SCStream sample handler thread.
    nonisolated func sendSystem(_ buffer: AVAudioPCMBuffer) {
        engine.send(buffer, isMic: false)
    }

    // MARK: – Disconnect

    /// Sends `{"type":"Finalize"}` to both Deepgram connections then waits up to
    /// `timeout` seconds for any pending speech to be emitted as final results.
    /// Call this before reading `transcript` when stopping, so the last utterance
    /// (which endpointing=300 would otherwise drop) lands before disconnect.
    func flushAndWait(timeout: Double = 0.7) async {
        guard isConnected else { return }
        engine.sendFinalize()
        // Brief drain — final results arrive via the receive loop on MainActor.
        // 0.7s > 300ms endpointing, gives Deepgram time to flush in-flight audio.
        try? await Task.sleep(for: .milliseconds(Int(timeout * 1000)))
    }

    func disconnect() {
        engine.teardown()
        isConnected   = false
        segments      = []
        transcript    = ""
        speakerToName = [:]
    }

    // MARK: – Receive loop

    private func startReceiveLoop(task: URLSessionWebSocketTask, isMic: Bool) {
        Task { @MainActor [weak self] in
            while let self {
                do {
                    let msg = try await task.receive()
                    self.handleMessage(msg, isMic: isMic)
                } catch {
                    NousLogger.warning("deepgram", "connection closed",
                                       ["stream": isMic ? "mic" : "sys",
                                        "err": error.localizedDescription])
                    self.isConnected = false
                    break
                }
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message, isMic: Bool) {
        var data: Data?
        switch message {
        case .data(let d):   data = d
        case .string(let s): data = s.data(using: .utf8)
        @unknown default:    return
        }
        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        // Only process final results (speech_final = utterance complete)
        guard let isFinal = json["is_final"] as? Bool, isFinal else { return }

        guard let channel      = json["channel"]      as? [String: Any],
              let alternatives = channel["alternatives"] as? [[String: Any]],
              let best         = alternatives.first
        else { return }

        let rawText = (best["transcript"] as? String ?? "")
            .trimmingCharacters(in: .whitespaces)
        guard !rawText.isEmpty else { return }

        let segStart = json["start"] as? Double ?? 0

        if isMic {
            // Mic — always the local user, no diarization needed
            append(Segment(start: segStart, label: "You", text: rawText))
        } else {
            // PRIVACY: never log verbatim transcript/speech — only a length signal.
            NousLogger.debug("deepgram", "sys final result", ["len": "\(rawText.count)"])
            // System audio — group consecutive words by speaker index
            let words = best["words"] as? [[String: Any]] ?? []
            if words.isEmpty {
                append(Segment(start: segStart, label: name(for: 0, at: segStart), text: rawText))
            } else {
                var groups: [(speaker: Int, words: [String], start: Double)] = []
                for word in words {
                    let speaker = word["speaker"] as? Int    ?? 0
                    let text    = word["word"]    as? String ?? ""
                    let wStart  = word["start"]   as? Double ?? segStart
                    if groups.last?.speaker == speaker {
                        groups[groups.count - 1].words.append(text)
                    } else {
                        groups.append((speaker, [text], wStart))
                    }
                }
                for group in groups {
                    let t = group.words.joined(separator: " ")
                        .trimmingCharacters(in: .whitespaces)
                    guard !t.isEmpty else { continue }
                    append(Segment(start: group.start,
                                   label: name(for: group.speaker, at: group.start),
                                   text: t))
                }
            }
        }
    }

    // MARK: – Helpers

    private func append(_ seg: Segment) {
        let idx = segments.firstIndex(where: { $0.start > seg.start }) ?? segments.endIndex
        segments.insert(seg, at: idx)
        transcript = segments.map { "\($0.label): \($0.text)" }.joined(separator: "\n")
        onUpdate(transcript)
    }

    /// Resolves a Deepgram speaker index to a display name.
    /// Priority:
    ///   1. Already-cached name for this index (stable once set)
    ///   2. Bridge speaker timeline lookup at `segStart` (Meet DOM active speaker)
    ///   3. Fallback: "Speaker N"
    private func name(for speaker: Int, at segStart: Double) -> String {
        if let cached = speakerToName[speaker] { return cached }

        // segStart is Deepgram's seconds-from-stream-start, which equals
        // seconds from recordingStartDate — pass directly to bridge lookup.
        if let bridgeName = bridgeSpeakerAt?(segStart) {
            speakerToName[speaker] = bridgeName
            // PRIVACY: participant names are PII — log only the speaker index.
            NousLogger.debug("deepgram", "speaker mapped via bridge",
                             ["index": speaker])
            return bridgeName
        }

        let n = speakerToName.count + 1
        let resolved = "Speaker \(n)"
        speakerToName[speaker] = resolved
        return resolved
    }

    /// Raw transcript prefixed with participant context for Gemini refinement.
    /// Returns just the transcript if no attendees were provided.
    var transcriptWithContext: String {
        guard !attendeeNames.isEmpty else { return transcript }
        let header = "Meeting participants: \(attendeeNames.joined(separator: ", "))"
        return transcript.isEmpty ? "" : "\(header)\n\n\(transcript)"
    }
}

// MARK: – AVAudioFormat cache key

private extension AVAudioFormat {
    var cacheKey: String { "\(sampleRate)_\(channelCount)_\(commonFormat.rawValue)" }
}

// MARK: – DeepgramSendEngine
//
// Plain (non-actor, non-MainActor) class. All work runs on its private serial
// DispatchQueue so audio tap callbacks can call send() directly without ever
// touching the main thread.  Uses NSLock for the converter cache which is the
// only shared mutable state.

final class DeepgramSendEngine: @unchecked Sendable {

    private let queue = DispatchQueue(label: "com.nous.deepgram.send",
                                      qos: .userInteractive)

    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate:   16_000,
        channels:     1,
        interleaved:  true
    )!

    private var micTask: URLSessionWebSocketTask?
    private var sysTask: URLSessionWebSocketTask?
    private var converterCache: [String: AVAudioConverter] = [:]
    private let lock = NSLock()

    // Called once on MainActor after connect; pre-warms mic converter.
    func configure(micTask: URLSessionWebSocketTask,
                   sysTask: URLSessionWebSocketTask,
                   micFormat: AVAudioFormat) {
        queue.async { [weak self] in
            guard let self else { return }
            lock.lock()
            self.micTask = micTask
            self.sysTask = sysTask
            if let conv = AVAudioConverter(from: micFormat, to: targetFormat) {
                converterCache[micFormat.cacheKey] = conv
            }
            lock.unlock()
        }
    }

    // Called directly from audio tap / SCStream handler — no Task, no MainActor.
    func send(_ buffer: AVAudioPCMBuffer, isMic: Bool) {
        let srcFormat  = buffer.format
        let frameCount = buffer.frameLength
        guard frameCount > 0 else { return }

        // Copy into a retained buffer so the queue closure is safe to use
        // after the caller's buffer may be recycled (AVAudioEngine tap reuse).
        // Uses a converter copy so both interleaved and non-interleaved float32
        // are handled uniformly — avoids the floatChannelData nil-for-interleaved trap.
        guard let copy = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: frameCount) else { return }
        copy.frameLength = frameCount

        let srcList = buffer.audioBufferList
        let dstList = copy.mutableAudioBufferList
        let bufCount = Int(srcList.pointee.mNumberBuffers)
        withUnsafePointer(to: srcList.pointee.mBuffers) { srcBufsPtr in
            withUnsafeMutablePointer(to: &dstList.pointee.mBuffers) { dstBufsPtr in
                for i in 0..<bufCount {
                    let src = (srcBufsPtr + i).pointee
                    let dst = (dstBufsPtr + i).pointee
                    guard let srcData = src.mData, let dstData = dst.mData else { continue }
                    memcpy(dstData, srcData, Int(src.mDataByteSize))
                }
            }
        }

        queue.async { [weak self] in
            self?.convert(copy, srcFormat: srcFormat, isMic: isMic)
        }
    }

    private func convert(_ buffer: AVAudioPCMBuffer,
                         srcFormat: AVAudioFormat,
                         isMic: Bool) {
        lock.lock()
        let task = isMic ? micTask : sysTask
        let converter: AVAudioConverter?
        if let cached = converterCache[srcFormat.cacheKey] {
            converter = cached
        } else if let fresh = AVAudioConverter(from: srcFormat, to: targetFormat) {
            converterCache[srcFormat.cacheKey] = fresh
            converter = fresh
        } else {
            converter = nil
        }
        lock.unlock()

        guard let task, let converter else { return }

        let ratio       = targetFormat.sampleRate / srcFormat.sampleRate
        let outFrames   = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: targetFormat,
                                            frameCapacity: outFrames) else { return }
        var err: NSError?
        let status = converter.convert(to: outBuf, error: &err) { _, s in
            s.pointee = .haveData; return buffer
        }
        guard status != .error, err == nil, outBuf.frameLength > 0,
              let ptr = outBuf.int16ChannelData?[0] else { return }

        let data = Data(bytes: ptr, count: Int(outBuf.frameLength) * 2)
        task.send(.data(data)) { _ in }
    }

    /// Sends `{"type":"Finalize"}` to both connections, asking Deepgram to flush
    /// any in-flight audio as final results before we stop sending data.
    func sendFinalize() {
        let msg = #"{"type":"Finalize"}"#
        queue.async { [weak self] in
            guard let self else { return }
            lock.lock()
            micTask?.send(.string(msg)) { _ in }
            sysTask?.send(.string(msg)) { _ in }
            lock.unlock()
        }
    }

    func teardown() {
        queue.async { [weak self] in
            guard let self else { return }
            let close = #"{"type":"CloseStream"}"#
            lock.lock()
            micTask?.send(.string(close)) { _ in }
            sysTask?.send(.string(close)) { _ in }
            micTask?.cancel(with: .normalClosure, reason: nil)
            sysTask?.cancel(with: .normalClosure, reason: nil)
            micTask = nil
            sysTask = nil
            converterCache = [:]
            lock.unlock()
        }
    }
}

#endif
