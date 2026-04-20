import Foundation
import CoreHaptics

@MainActor
final class Haptics {
    static let shared = Haptics()
    private var engine: CHHapticEngine?
    private var continuousPlayer: CHHapticAdvancedPatternPlayer?

    private init() { start() }

    private func start() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        do {
            engine = try CHHapticEngine()
            try engine?.start()
            engine?.resetHandler = { [weak self] in try? self?.engine?.start() }
            engine?.stoppedHandler = { _ in }
        } catch { engine = nil }
    }

    // Transients
    func tap()        { transient(intensity: 0.40, sharpness: 0.90, dur: 0.008) }
    func softTick()   { transient(intensity: 0.35, sharpness: 0.80, dur: 0.006) }
    func heavyThud()  { transient(intensity: 0.90, sharpness: 0.50, dur: 0.032) }
    func saveConfirm() { transient(intensity: 0.55, sharpness: 0.50, dur: 0.016) }
    func cancelCrash() {
        for i in 0..<3 {
            let delay = Double(i) * 0.10
            let intensity = Float(0.8 - Double(i) * 0.2)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.transient(intensity: intensity, sharpness: 0.9, dur: 0.010)
            }
        }
    }

    private func transient(intensity: Float, sharpness: Float, dur: Float) {
        guard let engine else { return }
        let e = CHHapticEvent(eventType: .hapticTransient,
                              parameters: [
                                .init(parameterID: .hapticIntensity, value: intensity),
                                .init(parameterID: .hapticSharpness, value: sharpness)
                              ], relativeTime: 0, duration: TimeInterval(dur))
        do {
            let pattern = try CHHapticPattern(events: [e], parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: 0)
        } catch { /* silent */ }
    }

    // Continuous — voice boil
    func startContinuous() {
        guard let engine, continuousPlayer == nil else { return }
        let e = CHHapticEvent(eventType: .hapticContinuous,
                              parameters: [
                                .init(parameterID: .hapticIntensity, value: 0.15),
                                .init(parameterID: .hapticSharpness, value: 0.40)
                              ], relativeTime: 0, duration: 60)
        do {
            let pattern = try CHHapticPattern(events: [e], parameters: [])
            continuousPlayer = try engine.makeAdvancedPlayer(with: pattern)
            try continuousPlayer?.start(atTime: 0)
        } catch { continuousPlayer = nil }
    }

    func updateContinuous(amp: Double) {
        let v = Float(max(0, min(1, amp)) * 0.6)
        let p = CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: v, relativeTime: 0)
        try? continuousPlayer?.sendParameters([p], atTime: 0)
    }

    func stopContinuous() {
        try? continuousPlayer?.stop(atTime: 0)
        continuousPlayer = nil
    }
}
