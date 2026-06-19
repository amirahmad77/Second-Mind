import Foundation
import AVFoundation
import Speech
import Observation

// VoiceRecorder — cross-platform.
// macOS: AVAudioEngine + SFSpeechRecognizer directly (no AVAudioSession).
// iOS:   same engine stack + AVAudioSession category management.
#if os(macOS)
@MainActor
@Observable
final class VoiceRecorder {
    private(set) var amp: Double = 0
    private(set) var isRecording = false

    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recogTask: SFSpeechRecognitionTask?
    private var transcript = ""

    // Resumed once when the recognizer reports its final hypothesis (or errors/ends).
    private var finalContinuation: CheckedContinuation<Void, Never>?
    private var didResumeFinal = false

    private func resumeFinalOnce() {
        guard !didResumeFinal else { return }
        didResumeFinal = true
        finalContinuation?.resume()
        finalContinuation = nil
    }

    func start() async {
        guard !isRecording else { return }
        guard recognizer?.isAvailable == true else {
            NousLogger.error("voice", "SFSpeechRecognizer unavailable on macOS")
            return
        }
        let speech = await Self.requestSpeechAuth()
        let mic    = await Self.requestMicAuth()
        guard speech && mic else {
            NousLogger.error("voice", "macOS speech or mic permission denied")
            return
        }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.taskHint = .dictation
        request  = req
        transcript = ""
        didResumeFinal = false

        recogTask = recognizer?.recognitionTask(with: req) { [weak self] result, err in
            guard let self else { return }
            if let err {
                NousLogger.error("voice", "recognition error", ["err": err.localizedDescription])
                Task { @MainActor [weak self] in self?.resumeFinalOnce() }
                return
            }
            guard let result else { return }
            let text = result.bestTranscription.formattedString
            let isFinal = result.isFinal
            Task { @MainActor [weak self] in
                self?.transcript = text
                if isFinal { self?.resumeFinalOnce() }
            }
        }

        let node = engine.inputNode
        let fmt  = node.outputFormat(forBus: 0)
        node.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buf, _ in
            req.append(buf)
            guard let ch = buf.floatChannelData?[0] else { return }
            let n = Int(buf.frameLength)
            var sum: Float = 0
            for i in 0..<n { sum += ch[i] * ch[i] }
            let rms  = sqrtf(sum / Float(max(n, 1)))
            let norm = min(1.0, Double(rms) * 12.0)
            Task { @MainActor [weak self] in self?.amp = norm }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            NousLogger.error("voice", "AVAudioEngine start failed", ["err": error.localizedDescription])
            return
        }
        isRecording = true
        NousLogger.info("voice", "macOS recording started")
    }

    func stop() async -> String {
        guard isRecording else { return transcript }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        request?.endAudio()
        isRecording = false
        amp = 0
        // Await the recognizer's final hypothesis instead of a fixed sleep, so
        // trailing words aren't clipped. Race against a safety timeout so we never hang.
        await awaitFinalResult(timeout: .seconds(2))
        recogTask?.finish()
        let final = transcript
        NousLogger.info("voice", "macOS recording stopped", ["chars": final.count])
        return final
    }

    /// Suspends until the recognizer reports its final result, the timeout elapses,
    /// or the recognition stream errors/ends. Resolves exactly once.
    private func awaitFinalResult(timeout: Duration) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor [weak self] in
                guard let self else { return }
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    if self.didResumeFinal { cont.resume(); return }
                    self.finalContinuation = cont
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
            }
            await group.next()
            group.cancelAll()
        }
        // Ensure the continuation can't be left dangling after the timeout path wins.
        resumeFinalOnce()
    }

    func cancel() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        request?.endAudio()
        recogTask?.cancel()
        resumeFinalOnce()
        isRecording = false
        amp = 0
        transcript = ""
    }

    private static func requestSpeechAuth() async -> Bool {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
    }

    /// On macOS use AVCaptureDevice (AVAudioSession is iOS-only).
    private static func requestMicAuth() async -> Bool {
        await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                cont.resume(returning: granted)
            }
        }
    }
}
#else

@MainActor
@Observable
final class VoiceRecorder {
    private(set) var amp: Double = 0
    private(set) var isRecording = false

    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var transcript = ""

    // Resumed once when the recognizer reports its final hypothesis (or errors/ends).
    private var finalContinuation: CheckedContinuation<Void, Never>?
    private var didResumeFinal = false

    private func resumeFinalOnce() {
        guard !didResumeFinal else { return }
        didResumeFinal = true
        finalContinuation?.resume()
        finalContinuation = nil
    }

    func start() async {
        guard !isRecording else { return }
        guard recognizer?.isAvailable == true else { return } // recognizer nil or offline-unsupported locale
        let speech = await Self.requestSpeechAuth()
        let mic = await Self.requestMicAuth()
        guard speech && mic else { return }

        try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        request = req
        transcript = ""
        didResumeFinal = false

        task = recognizer?.recognitionTask(with: req) { [weak self] result, err in
            guard let self else { return }
            if err != nil {
                Task { @MainActor [weak self] in self?.resumeFinalOnce() }
                return
            }
            guard let result else { return }
            let text = result.bestTranscription.formattedString
            let isFinal = result.isFinal
            Task { @MainActor [weak self] in
                self?.transcript = text
                if isFinal { self?.resumeFinalOnce() }
            }
        }

        let node = engine.inputNode
        let fmt = node.outputFormat(forBus: 0)
        node.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buf, _ in
            req.append(buf)
            guard let ch = buf.floatChannelData?[0] else { return }
            let n = Int(buf.frameLength)
            var sum: Float = 0
            for i in 0..<n { sum += ch[i] * ch[i] }
            let rms = sqrtf(sum / Float(max(n, 1)))
            let norm = min(1.0, Double(rms) * 12.0)   // empirical scaler
            Task { @MainActor [weak self] in self?.amp = norm }
        }
        engine.prepare()
        do { try engine.start() } catch { return }
        isRecording = true
    }

    /// Stops capture and returns final transcript (may be empty).
    func stop() async -> String {
        guard isRecording else { return "" }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        request?.endAudio()
        isRecording = false
        amp = 0
        // Await the recognizer's final hypothesis instead of a fixed sleep, so
        // trailing words aren't clipped. Race against a safety timeout so we never hang.
        await awaitFinalResult(timeout: .seconds(2))
        task?.finish()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return transcript
    }

    /// Suspends until the recognizer reports its final result, the timeout elapses,
    /// or the recognition stream errors/ends. Resolves exactly once.
    private func awaitFinalResult(timeout: Duration) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor [weak self] in
                guard let self else { return }
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    if self.didResumeFinal { cont.resume(); return }
                    self.finalContinuation = cont
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
            }
            await group.next()
            group.cancelAll()
        }
        // Ensure the continuation can't be left dangling after the timeout path wins.
        resumeFinalOnce()
    }

    func cancel() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        request?.endAudio()
        task?.cancel()
        resumeFinalOnce()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isRecording = false
        amp = 0
        transcript = ""
    }

    private static func requestSpeechAuth() async -> Bool {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
        }
    }
    private static func requestMicAuth() async -> Bool {
        await withCheckedContinuation { cont in
            AVAudioApplication.requestRecordPermission { cont.resume(returning: $0) }
        }
    }
}

#endif
