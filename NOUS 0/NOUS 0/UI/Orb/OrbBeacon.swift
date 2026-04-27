import SwiftUI

/// OrbBeacon — pill redesign.
///
/// Concept: the orb speaks the app's own language.
/// Every surface in NOUS uses "// label" mono chrome (// daily, // random,
/// // on this day). The capture button should too.
///
/// Design:
///   - inkRaised capsule + hairline phosphor border (no glow, no glass, no shadow).
///   - Idle: `• // capture` — 6pt dot breathes on a 3s sine, text follows.
///     Only the opacity moves; no layout shift.
///   - TextActive: dot + `// writing`, cyan at full phosphor.
///   - Voice: inline amp bars + `// listening`, amber → orange at high amp.
///     Bars are the amp indicator; the label anchors meaning.
///   - VoiceCancel: label collapses to `// discard`, ghost tint, pill slightly
///     narrower so the gesture read is "retreating".
///   - Search / Synthesis: dot + `// search` or `// think`, tinted per mode.
///   - Refining: dot + `// refining` + a 22% capsule trim rotates around the
///     pill border at 1.4s linear — ambient, not urgent.
///
/// Animation rules (Emil):
///   - State transitions: .smooth(duration: 0.22) — fast, never jarring.
///   - Continuous motion (refining arc): linear, 1.4s.
///   - Voice bars: spring(response: 0.28, damp: 0.62) — interruptible.
///   - Idle breath: 2fps TimelineView, 3s sine — near-zero CPU.
struct OrbBeacon: View {
    let mode: OrbMode

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast)       private var contrast

    // Fixed pill geometry. Width never animates — prevents layout jumps.
    private let pillW: CGFloat = 176
    private let pillH: CGFloat = 46

    var body: some View {
        pill
            .animation(.smooth(duration: 0.22), value: ModeKey(mode))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(a11yLabel)
    }

    // MARK: - State dispatch

    @ViewBuilder
    private var pill: some View {
        switch mode {
        case .idle:               idlePill
        case .textActive:         textPill
        case .voice(let amp):     voicePill(amp: amp)
        case .voiceCancelZone:    cancelPill
        case .search:             labelPill("// search",  tint: col(NSColorToken.Phos.blue))
        case .synthesis:          labelPill("// think",   tint: col(NSColorToken.Phos.violet))
        case .refining:           refiningPill
        }
    }

    // MARK: - Idle

    /// Everything driven by a single 2fps TimelineView (3s sine period).
    /// BreathDot animates independently via Core Animation — no extra cost.
    /// Border opacity breathes alongside the label: both inhale/exhale together.
    private var idlePill: some View {
        let tint = col(NSColorToken.Phos.cyan)
        return ZStack {
            if reduceMotion {
                shell(tint: tint)
                HStack(spacing: 8) {
                    Circle().fill(tint.opacity(0.58)).frame(width: 5, height: 5)
                    Text("// capture")
                        .font(NFont.mono(12))
                        .foregroundStyle(NSColorToken.textTertiary)
                }
            } else {
                TimelineView(.animation(minimumInterval: 0.5)) { ctx in
                    let t = ctx.date.timeIntervalSinceReferenceDate
                    let α = CGFloat(0.5 + 0.5 * sin(t * 2.0 * .pi / 3.0))  // 0…1, 3s
                    ZStack {
                        // Border breathes: 0.14 → 0.32 opacity
                        shell(tint: tint, borderOpacity: 0.14 + 0.18 * Double(α))
                        HStack(spacing: 8) {
                            BreathDot(tint: tint)  // Core Animation, independent
                            Text("// capture")
                                .font(NFont.mono(12))
                                .foregroundStyle(
                                    NSColorToken.textTertiary.opacity(0.36 + 0.42 * α)
                                )
                        }
                    }
                }
            }
        }
    }

    // MARK: - Text active

    private var textPill: some View {
        let tint = col(NSColorToken.Phos.cyan)
        return ZStack {
            shell(tint: tint)
            pillContent(dot: tint, label: "// writing", labelColor: tint.opacity(0.90))
        }
    }

    // MARK: - Voice

    private func voicePill(amp: Double) -> some View {
        let a   = max(0, min(1, amp))
        let hot = a > 0.78 ? NSColorToken.Phos.orange : NSColorToken.Phos.amber
        let tint = col(hot)
        return ZStack {
            shell(tint: tint)
            HStack(spacing: 10) {
                AmpBars(amp: a, tint: tint)
                    .frame(width: 22, height: 18)
                Text("// listening")
                    .font(NFont.mono(12))
                    .foregroundStyle(tint.opacity(0.90))
            }
        }
    }

    // MARK: - Cancel zone

    private var cancelPill: some View {
        let tint = col(NSColorToken.textGhost)
        return ZStack {
            // Shell deliberately uses low tint opacity — the visual collapse
            // communicates "danger / retreating" without an explicit warning color.
            shell(tint: tint.opacity(0.30))
            Text("// discard")
                .font(NFont.mono(12))
                .foregroundStyle(tint.opacity(0.50))
        }
    }

    // MARK: - Search / Synthesis (generic labelled)

    private func labelPill(_ label: String, tint: Color) -> some View {
        ZStack {
            shell(tint: tint)
            pillContent(dot: tint, label: label, labelColor: tint.opacity(0.90))
        }
    }

    // MARK: - Refining

    private var refiningPill: some View {
        let tint = col(NSColorToken.Phos.amber)
        return ZStack {
            shell(tint: tint.opacity(0.50))
            pillContent(dot: tint, label: "// refining",
                        labelColor: tint.opacity(0.80))
            // Spinning 22% capsule arc traces the pill outline.
            // Linear = continuous work in progress; 1.4s feels ambient, not urgent.
            if !reduceMotion {
                TimelineView(.animation(minimumInterval: 1.0 / 45.0)) { ctx in
                    let t   = ctx.date.timeIntervalSinceReferenceDate
                    let deg = (t.truncatingRemainder(dividingBy: 1.4)) / 1.4 * 360.0
                    Capsule()
                        .trim(from: 0, to: 0.22)
                        .stroke(
                            tint.opacity(0.65),
                            style: StrokeStyle(lineWidth: 1.0, lineCap: .round)
                        )
                        .frame(width: pillW, height: pillH)
                        .rotationEffect(.degrees(deg))
                }
            }
        }
    }

    // MARK: - Primitives

    /// Capsule shell: inkRaised fill + hairline phosphor border.
    /// `borderOpacity` defaults to 0.32; idle passes a breathing value.
    private func shell(tint: Color, borderOpacity: Double = 0.32) -> some View {
        ZStack {
            Capsule()
                .fill(NSColorToken.inkRaised)
            Capsule()
                .strokeBorder(tint.opacity(borderOpacity), lineWidth: 0.5)
        }
        .frame(width: pillW, height: pillH)
    }

    /// Standard dot + label layout used by most states.
    private func pillContent(dot: Color, label: String, labelColor: Color) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(dot)
                .frame(width: 6, height: 6)
            Text(label)
                .font(NFont.mono(12))
                .foregroundStyle(labelColor)
        }
    }

    // MARK: - Helpers

    private func col(_ c: Color) -> Color {
        contrast == .increased ? NSColorToken.textPrimary : c
    }

    private var a11yLabel: String {
        switch mode {
        case .idle:               return "capture"
        case .textActive:         return "capture, writing"
        case .voice(let a):       return "capture, listening, level \(Int(a * 100)) percent"
        case .voiceCancelZone:    return "capture, release to discard"
        case .search:             return "search"
        case .synthesis:          return "think"
        case .refining:           return "capture, refining"
        }
    }
}

// MARK: - Breath dot (idle)

/// A 5pt dot that slowly scales 5→7pt and brightens 0.42→0.80 opacity.
/// Uses `.animation(.repeatForever)` so Core Animation owns the loop —
/// no timer, no task, no main-thread cost.
private struct BreathDot: View {
    let tint: Color
    @State private var inhale = false

    var body: some View {
        Circle()
            .fill(tint.opacity(inhale ? 0.80 : 0.42))
            .frame(width: inhale ? 7 : 5, height: inhale ? 7 : 5)
            .animation(
                .easeInOut(duration: 2.8).repeatForever(autoreverses: true),
                value: inhale
            )
            .onAppear { inhale = true }
    }
}

// MARK: - Voice amplitude bars

/// Three vertical bars that track voice amplitude via springs.
/// Springs (not CSS transitions) because amplitude interrupts itself
/// constantly — springs maintain velocity, transitions restart from zero.
private struct AmpBars: View {
    let amp:  Double
    let tint: Color

    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            bar(height: 3 + CGFloat(clamp(amp * 1.10)) * 11)
            bar(height: 3 + CGFloat(clamp(amp * 1.30)) * 14)
            bar(height: 3 + CGFloat(clamp(amp * 0.90)) * 10)
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.62), value: amp)
    }

    private func bar(height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
            .fill(tint.opacity(0.88))
            .frame(width: 2.5, height: max(2, min(15, height)))
    }

    private func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
}

// MARK: - Mode key

/// Collapses OrbMode to a string so `.animation(_:value:)` fires only on
/// real state changes — not on every amp update inside `.voice`.
private struct ModeKey: Equatable {
    let raw: String
    init(_ m: OrbMode) {
        switch m {
        case .idle:            raw = "idle"
        case .textActive:      raw = "text"
        case .voice:           raw = "voice"
        case .voiceCancelZone: raw = "cancel"
        case .search:          raw = "search"
        case .synthesis:       raw = "synthesis"
        case .refining:        raw = "refining"
        }
    }
}
