#if os(macOS)
import AVFoundation
import ScreenCaptureKit
import CoreGraphics
import Observation

// ─── MacMeetingRecorder ────────────────────────────────────────────────────────
//
// Granola-style meeting recorder for macOS.
//
// Audio capture:
//   • Mic   — AVAudioEngine inputNode tap (your voice)
//   • System audio — ScreenCaptureKit SCStream (everyone on the call:
//     Zoom, Meet, Teams, phone, anything)
//     Requires macOS 12.3+ and Screen & System Audio Recording permission.
//     Falls back to mic-only silently if unavailable.
//
// Transcription:
//   GeminiLiveTranscriber — streams mixed PCM to gemini-3.1-flash-live-preview
//   via WebSocket. Gemini identifies distinct voices in real-time and attributes
//   them: "You:" (mic, primary voice) vs "Speaker 1:", "Speaker 2:", etc.
//   The transcript is live — visible in MacMeetRecordBar as speech happens.
//
// On stop:
//   Returns the full diarized transcript string.
//   Caller calls store.capture(raw: transcript, type: .meeting) → Gemini refine
//   pipeline formats it into ## decisions / ## action items / ## open questions.

@MainActor
@Observable
final class MacMeetingRecorder {
    private(set) var isRecording:       Bool         = false
    private(set) var duration:          TimeInterval = 0
    private(set) var micAmp:            Double       = 0
    private(set) var partialTranscript: String       = ""
    /// true once ScreenCaptureKit system audio starts (mic+call vs mic-only)
    private(set) var systemAudioActive: Bool         = false
    /// Non-nil when start() fails — human-readable reason shown in UI
    var lastError:         String?
    /// Stable ID for this meeting session. Either the Google Meet room code
    /// ("abc-defg-hij") or a generated UUID. Used by callers to detect
    /// reconnections to the same call and update the existing atom.
    private(set) var meetingSessionID:  String       = ""

    private let engine        = AVAudioEngine()
    private let transcriber   = DeepgramLiveTranscriber()
    private var scStream:     SCStream?
    private var scAudioBridge: AnyObject?   // strong ref — SCKit holds delegate weakly
    private var timerTask:    Task<Void, Never>?

    // Speaker timeline — bridge onSpeakerChange events during recording.
    // Each entry: seconds from recordingStartDate → speaker name from Meet DOM.
    private var speakerHistory:     [(offset: TimeInterval, name: String)] = []
    private var recordingStartDate: Date?

    // Set by caller (MacRootView) so we can read participants / speaker from it.
    weak var bridge: MeetBridgeServer?

    // Guards against re-entry during await suspension in start()
    private var isStarting = false

    // MARK: – Start

    /// `attendees` — comma-separated names of meeting participants (optional).
    /// If empty, MeetParticipantWatcher auto-detects names from the Meet tab.
    func start(attendees: String = "") async {
        guard !isRecording, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        lastError = nil

        let micOK = await Self.requestMicAuth()
        guard micOK else {
            lastError = "Microphone access denied. Go to System Settings → Privacy → Microphone and enable NOUS."
            NousLogger.error("meet", "mic permission denied")
            return
        }

        partialTranscript   = ""
        duration            = 0
        systemAudioActive   = false
        speakerHistory      = []
        recordingStartDate  = Date()
        // Stable session ID per meeting occurrence:
        //   roomCode-YYYY-MM-DD  e.g. "abc-defg-hij-2026-04-30"
        // • Unique across weekly recurrences of the same room URL
        // • Stable across mid-meeting disconnects/reconnects on the same day
        // • Falls back to a UUID for non-Meet recordings or when bridge isn't connected
        if let roomCode = bridge?.meetingRoomID, !roomCode.isEmpty {
            let day = Self.dateTag()
            meetingSessionID = "\(roomCode)-\(day)"
        } else {
            meetingSessionID = UUID().uuidString
        }

        // Wire bridge → speaker timeline so Deepgram sys segments get real names.
        if let bridge {
            let startDate = recordingStartDate!
            bridge.onSpeakerChange = { [weak self] name in
                guard let self, let name, !name.isEmpty else { return }
                let offset = Date().timeIntervalSince(startDate)
                self.speakerHistory.append((offset: offset, name: name))
            }
            // Capture current speaker immediately if someone is already talking
            if let current = bridge.activeSpeaker, !current.isEmpty {
                speakerHistory.append((offset: 0, name: current))
            }
        }

        // Auto-detect attendees from the Chrome extension bridge (if connected).
        var resolvedAttendees = attendees
        if resolvedAttendees.isEmpty, let bridge {
            let detected = bridge.participants
            if !detected.isEmpty {
                resolvedAttendees = detected.joined(separator: ", ")
                NousLogger.info("meet", "bridge attendees", ["names": resolvedAttendees])
            }
        }

        // Connect transcriber FIRST — we need the converter built before
        // installing the audio tap so the input format is known.
        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        do {
            try await transcriber.connect(inputFormat: inputFormat, attendees: resolvedAttendees)
        } catch {
            let msg = error.localizedDescription
            if msg.contains("API key") || msg.contains("not set") {
                lastError = "Deepgram API key not configured. Add NOUS_DEEPGRAM_API_KEY to LocalSecrets.xcconfig."
            } else {
                lastError = "Couldn't connect to Deepgram: \(msg)"
            }
            NousLogger.error("meet", "Deepgram connect failed", ["err": msg])
            return
        }

        // Route transcriber updates → partialTranscript
        transcriber.onUpdate = { [weak self] text in
            self?.partialTranscript = text
        }

        // Bridge speaker lookup: given segment start offset (seconds from stream start),
        // return the speaker name from the Meet DOM timeline. Transcriber uses this
        // instead of guessing from Deepgram speaker index order.
        transcriber.bridgeSpeakerAt = { [weak self] offset in
            self?.speakerNameAt(offset: offset)
        }

        // Start mic tap → send to Deepgram
        await startMicTap()

        // Attempt system audio (ScreenCaptureKit)
        await startSystemAudio()

        isRecording = true
        bridge?.sendRecordingState(true)
        timerTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { break }
                duration += 0.5
            }
        }
        NousLogger.info("meet", "recording started",
                        ["mode": systemAudioActive ? "mic+system" : "mic-only"])
    }

    // MARK: – Stop

    func stop() async -> String {
        guard isRecording else { return transcriber.transcriptWithContext }
        timerTask?.cancel(); timerTask = nil

        // Flush Deepgram before snapshot: sends {"type":"Finalize"} to both
        // connections and waits 700ms so the last utterance (which endpointing=300
        // would otherwise drop) lands as a final result before we read transcript.
        await transcriber.flushAndWait(timeout: 0.7)

        // Snapshot transcript after flush, before teardown.
        // Use transcriptWithContext — prefixes "Meeting participants: ..." so Gemini
        // can do proper speaker attribution during refinement.
        let final = transcriber.transcriptWithContext

        // Silence further onUpdate callbacks immediately — prevents burst of
        // Deepgram final-results firing handleMessage on MainActor all at once
        // (O(n²) transcript rebuild) which causes the post-call UI freeze.
        transcriber.onUpdate        = { (_: String) in }
        transcriber.bridgeSpeakerAt = nil
        bridge?.onSpeakerChange     = { _ in }

        isRecording        = false
        micAmp             = 0
        speakerHistory     = []
        recordingStartDate = nil
        bridge?.sendRecordingState(false)

        // Disconnect Deepgram immediately (fast — just cancels WebSocket tasks).
        // This kills the receive loops now so no more handleMessage fires on MainActor.
        transcriber.disconnect()

        // Capture locals so detached task doesn't retain self
        let eng    = engine
        let stream = scStream
        scStream      = nil
        scAudioBridge = nil

        // Detach the blocking cleanup — AVAudioEngine.stop() + SCStream.stopCapture()
        // can block; neither must run on MainActor.
        Task.detached(priority: .utility) {
            if eng.isRunning {
                eng.inputNode.removeTap(onBus: 0)
                eng.stop()
            }
            if let stream {
                // SCKit stopCapture can hang — cap at 3s
                try? await withTimeout(seconds: 3) {
                    try await stream.stopCapture()
                }
            }
        }

        NousLogger.info("meet", "recording stopped", ["chars": final.count])
        return final
    }

    // MARK: – Helpers

    /// Returns today's date as "YYYY-MM-DD" in the device's local timezone.
    /// Used to disambiguate weekly recurring meetings that share the same room code.
    private static func dateTag() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }

    // MARK: – Cancel

    // MARK: – Speaker timeline lookup

    /// Returns the speaker name active at `offset` seconds from recording start.
    /// Uses the most recent bridge speaker change event at or before the offset.
    private func speakerNameAt(offset: TimeInterval) -> String? {
        guard !speakerHistory.isEmpty else { return nil }
        // Find last entry whose offset ≤ segment start
        let match = speakerHistory.last(where: { $0.offset <= offset })
            ?? speakerHistory.first
        return match?.name
    }

    func cancel() {
        timerTask?.cancel(); timerTask = nil
        transcriber.onUpdate     = { (_: String) in }
        transcriber.bridgeSpeakerAt = nil
        transcriber.disconnect()
        bridge?.onSpeakerChange  = { _ in }
        bridge?.sendRecordingState(false)
        isRecording        = false
        micAmp             = 0
        duration           = 0
        partialTranscript  = ""
        systemAudioActive  = false
        speakerHistory     = []
        recordingStartDate = nil
        meetingSessionID   = ""

        let eng    = engine
        let stream = scStream
        scStream      = nil
        scAudioBridge = nil
        Task.detached(priority: .utility) {
            if eng.isRunning {
                eng.inputNode.removeTap(onBus: 0)
                eng.stop()
            }
            if let stream {
                try? await stream.stopCapture()
            }
        }
    }

    // MARK: – Mic tap

    private func startMicTap() async {
        let node = engine.inputNode
        let fmt  = node.outputFormat(forBus: 0)

        node.installTap(onBus: 0, bufferSize: 4096, format: fmt) { [weak self] buf, _ in
            guard let self else { return }

            // Amplitude for the visual bar
            if let ch = buf.floatChannelData?[0] {
                let n    = Int(buf.frameLength)
                var sum: Float = 0
                for i in 0..<n { sum += ch[i] * ch[i] }
                let norm = min(1.0, Double(sqrtf(sum / Float(max(n, 1)))) * 12.0)
                Task { @MainActor [weak self] in
                    // Drop amplitude updates once recording stopped —
                    // prevents extra @Observable notifications during fade-out.
                    guard let self, self.isRecording else { return }
                    self.micAmp = norm
                }
            }

            // Send directly — nonisolated, runs on sendQueue (never touches MainActor)
            self.transcriber.sendMic(buf)
        }
        engine.prepare()
        do { try engine.start() } catch {
            NousLogger.error("meet", "AVAudioEngine start failed",
                             ["err": error.localizedDescription])
        }
    }

    // MARK: – System audio (ScreenCaptureKit)

    private func startSystemAudio() async {
        guard #available(macOS 12.3, *) else { return }

        // Request Screen & System Audio Recording permission explicitly.
        // CGRequestScreenCaptureAccess() shows the system dialog on first call;
        // returns true immediately if already granted.
        guard CGRequestScreenCaptureAccess() else {
            lastError = "Screen & System Audio Recording access required to transcribe other participants. Go to System Settings → Privacy & Security → Screen & System Audio Recording, enable NOUS, then restart the app."
            NousLogger.warning("meet", "screen capture permission denied — mic-only mode")
            return
        }

        do {
            let content = try await SCShareableContent.current
            guard let display = content.displays.first else { return }

            let filter = SCContentFilter(display: display,
                                         excludingApplications: [],
                                         exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.sampleRate    = 16_000
            config.channelCount  = 1

            // Reuse the same AVAudioFormat the transcriber was built with
            guard let sysFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: 16_000,
                                             channels: 1,
                                             interleaved: false) else { return }

            let audioBridge = SCStreamAudioBridge(transcriber: transcriber, format: sysFmt)
            let stream = SCStream(filter: filter, configuration: config, delegate: audioBridge)
            try stream.addStreamOutput(audioBridge, type: .audio,
                                       sampleHandlerQueue: .global(qos: .userInteractive))
            try await stream.startCapture()
            scStream          = stream
            scAudioBridge     = audioBridge  // retain strongly — SCKit holds delegate weakly
            systemAudioActive = true
            NousLogger.info("meet", "ScreenCaptureKit system audio active")
        } catch {
            NousLogger.warning("meet", "ScreenCaptureKit start failed — mic-only",
                               ["reason": error.localizedDescription])
        }
    }

    // MARK: – Permissions

    private static func requestMicAuth() async -> Bool {
        await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .audio) { cont.resume(returning: $0) }
        }
    }
}

// MARK: – SCStream → DeepgramLiveTranscriber bridge

/// Converts ScreenCaptureKit CMSampleBuffers to AVAudioPCMBuffer
/// and forwards them to the Deepgram system-audio connection.
@available(macOS 12.3, *)
private final class SCStreamAudioBridge: NSObject, SCStreamDelegate, SCStreamOutput {
    private let transcriber: DeepgramLiveTranscriber
    private let format: AVAudioFormat

    init(transcriber: DeepgramLiveTranscriber, format: AVAudioFormat) {
        self.transcriber = transcriber
        self.format      = format
    }

    // Throttle log — only log first frame + every 200th to avoid spam
    private var sysFrameCount = 0

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard let pcm = Self.pcmBuffer(from: sampleBuffer, targetFormat: format) else {
            NousLogger.warning("meet", "SCStream audio → pcmBuffer conversion failed")
            return
        }
        sysFrameCount += 1
        if sysFrameCount == 1 || sysFrameCount % 200 == 0 {
            NousLogger.debug("meet", "SCStream sys audio flowing",
                             ["frame": sysFrameCount, "frameLength": pcm.frameLength,
                              "sampleRate": pcm.format.sampleRate])
        }
        // Send directly — nonisolated, never touches MainActor
        transcriber.sendSystem(pcm)
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        NousLogger.error("meet", "SCStream stopped", ["err": error.localizedDescription])
    }

    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer,
                                  targetFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        let srcFormat = AVAudioFormat(cmAudioFormatDescription: formatDesc)
        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0 else { return nil }

        // Allocate a float32 PCM buffer for the source data
        guard let srcBuf = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: frameCount) else { return nil }
        srcBuf.frameLength = frameCount
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frameCount),
            into: srcBuf.mutableAudioBufferList)
        guard status == noErr else { return nil }

        // If source is already the target format, return as-is
        if srcFormat == targetFormat { return srcBuf }

        // Otherwise convert (resample / channel-fold)
        guard let converter = AVAudioConverter(from: srcFormat, to: targetFormat) else { return srcBuf }
        let outFrames = AVAudioFrameCount(Double(frameCount) * targetFormat.sampleRate / srcFormat.sampleRate) + 1
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outFrames) else { return srcBuf }
        var err: NSError?
        let result = converter.convert(to: outBuf, error: &err) { _, status in
            status.pointee = .haveData
            return srcBuf
        }
        return result == .error ? srcBuf : outBuf
    }
}

// MARK: – withTimeout

/// Runs `operation` and cancels it if it doesn't complete within `seconds`.
/// Throws `CancellationError` on timeout.
func withTimeout<T: Sendable>(
    seconds: Double,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw CancellationError()
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

#endif
