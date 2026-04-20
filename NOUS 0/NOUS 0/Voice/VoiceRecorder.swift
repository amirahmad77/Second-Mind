import Foundation
import AVFoundation
import Speech
import Observation

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

        task = recognizer?.recognitionTask(with: req) { [weak self] result, err in
            guard let self else { return }
            if err != nil { return }
            guard let result else { return }
            Task { @MainActor [weak self] in self?.transcript = result.bestTranscription.formattedString }
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
        task?.finish()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isRecording = false
        amp = 0
        // Give recognizer a beat to flush
        try? await Task.sleep(for: .milliseconds(150))
        return transcript
    }

    func cancel() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        request?.endAudio()
        task?.cancel()
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
