import AVFoundation
import Foundation

/// Tiny TE-coded micro-audio cues to give the orb instrument feel.
/// Mirrors Haptics — singleton, lazy AVAudioEngine, generated buffers (no asset
/// files). All cues are sub-300ms, pre-rendered once at first play, then
/// scheduled on demand.
///
/// Toggle via UserDefaults key `nous.sound.enabled` (default off — opt in).
final class SoundFX {
    static let shared = SoundFX()

    static let enabledKey = "nous.sound.enabled"

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private var buffers: [Cue: AVAudioPCMBuffer] = [:]
    private var started = false

    enum Cue: String {
        case captureCommit
        case refineReady
        case voiceCommit
        case voiceCancel
        case searchLand
    }

    private init() {
        // 44.1kHz mono, float — universally supported, easy math.
        self.format = AVAudioFormat(
            standardFormatWithSampleRate: 44_100, channels: 1
        )!
    }

    // MARK: - Public

    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? false
    }

    func play(_ cue: Cue) {
        guard isEnabled else { return }
        ensureStarted()
        guard let buf = buffer(for: cue) else { return }
        player.scheduleBuffer(buf, at: nil, options: [.interrupts], completionHandler: nil)
        if !player.isPlaying { player.play() }
    }

    /// Convenience semantics — what callers actually want to express.
    func captureCommit() { play(.captureCommit) }
    func refineReady()   { play(.refineReady) }
    func voiceCommit()   { play(.voiceCommit) }
    func voiceCancel()   { play(.voiceCancel) }
    func searchLand()    { play(.searchLand) }

    // MARK: - Engine lifecycle

    private func ensureStarted() {
        guard !started else { return }
        do {
            #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
            // Mix w/ other audio (music, podcasts) — these cues are decoration.
            try AVAudioSession.sharedInstance().setCategory(
                .ambient, mode: .default, options: [.mixWithOthers]
            )
            try AVAudioSession.sharedInstance().setActive(true)
            #endif
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            try engine.start()
            started = true
        } catch {
            // Silent — sound is decorative; do not surface failures.
            started = false
        }
    }

    // MARK: - Buffer synthesis

    private func buffer(for cue: Cue) -> AVAudioPCMBuffer? {
        if let cached = buffers[cue] { return cached }
        let buf = synthesize(cue)
        buffers[cue] = buf
        return buf
    }

    private func synthesize(_ cue: Cue) -> AVAudioPCMBuffer? {
        switch cue {
        case .captureCommit:
            // 1kHz blip, 60ms, sharp attack + exp decay. Tactile "k" click.
            return makeBuffer(durationMs: 60) { i, sr in
                let t = Float(i) / sr
                let env = Self.expDecay(t: t, tau: 0.020)
                return Self.sine(freq: 1000, t: t) * env * 0.55
            }

        case .refineReady:
            // Descending two-tone bloop: 660 → 440Hz over 220ms.
            return makeBuffer(durationMs: 220) { i, sr in
                let t = Float(i) / sr
                let dur: Float = 0.220
                let freq = 660 - 220 * (t / dur)
                let env = Self.adsr(t: t, dur: dur, attack: 0.012, release: 0.060)
                return Self.sine(freq: freq, t: t) * env * 0.45
            }

        case .voiceCommit:
            // Bright confirm: 1.2kHz, 110ms, soft decay. "ping".
            return makeBuffer(durationMs: 110) { i, sr in
                let t = Float(i) / sr
                let env = Self.expDecay(t: t, tau: 0.045)
                return Self.sine(freq: 1200, t: t) * env * 0.50
            }

        case .voiceCancel:
            // Detuned glitch: 3 fast 90Hz pulses w/ noise — "no".
            return makeBuffer(durationMs: 200) { i, sr in
                let t = Float(i) / sr
                let pulseIdx = Int(t * 18) % 3      // 3 pulses across the duration
                if pulseIdx > 1 { return 0 }        // gap between pulses
                let env = Self.expDecay(t: t.truncatingRemainder(dividingBy: 0.055), tau: 0.012)
                let noise = Float.random(in: -0.3...0.3)
                return (Self.square(freq: 90, t: t) + noise * 0.5) * env * 0.45
            }

        case .searchLand:
            // Soft phosphor "wash": pink-ish noise burst, fades over 280ms.
            return makeBuffer(durationMs: 280) { i, sr in
                let t = Float(i) / sr
                let env = Self.adsr(t: t, dur: 0.280, attack: 0.030, release: 0.180)
                let n = Float.random(in: -1...1) * 0.6
                let lp = Self.sine(freq: 380, t: t) * 0.25
                return (n + lp) * env * 0.30
            }
        }
    }

    private func makeBuffer(durationMs: Int,
                            sample: (Int, Float) -> Float) -> AVAudioPCMBuffer? {
        let sr = Float(format.sampleRate)
        let frames = AVAudioFrameCount(Float(durationMs) / 1000.0 * sr)
        guard frames > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
        else { return nil }
        buf.frameLength = frames
        guard let data = buf.floatChannelData?[0] else { return nil }
        for i in 0..<Int(frames) {
            data[i] = sample(i, sr)
        }
        return buf
    }

    // MARK: - DSP helpers

    private static func sine(freq: Float, t: Float) -> Float {
        sin(2 * .pi * freq * t)
    }

    private static func square(freq: Float, t: Float) -> Float {
        sin(2 * .pi * freq * t) >= 0 ? 1 : -1
    }

    private static func expDecay(t: Float, tau: Float) -> Float {
        guard t >= 0 else { return 0 }
        return exp(-t / tau)
    }

    private static func adsr(t: Float, dur: Float, attack: Float, release: Float) -> Float {
        guard t >= 0, t <= dur else { return 0 }
        if t < attack { return t / attack }
        let releaseStart = dur - release
        if t > releaseStart { return max(0, 1 - (t - releaseStart) / release) }
        return 1
    }
}
