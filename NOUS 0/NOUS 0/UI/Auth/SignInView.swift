import SwiftUI

/// Full-screen sign-in surface. Shown when no `AuthSession` exists in Keychain.
///
/// Layout:
///   - Top half: ambient phosphor halo backdrop, centered NOUS wordmark
///   - Bottom: single Google sign-in pill, version label, error toast
///
/// Motion (per Emil):
///   - Wordmark fades + lifts 12pt on appear (420ms cubic-out)
///   - Halo breathes 4.2s sine
///   - Google button: scale 0.97 + opacity 0.85 on press, soft tick haptic
///   - During sign-in: button label morphs to mono "// opening browser…",
///     halo intensifies 18% (cyan), then settles back on dismissal
///   - Error toast: slides up from bottom 240ms ease-out, auto-dismisses 4s
struct SignInView: View {
    @Bindable var auth: AuthClient
    var onSignedIn: () -> Void = {}

    @State private var wordmarkVisible = false
    @State private var haloPulse = false
    @State private var visibleError: String?
    @State private var errorTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            NSColorToken.inkVoid
                .ignoresSafeArea()
                .allowsHitTesting(false)
            backdrop

            VStack(spacing: 0) {
                Spacer()
                wordmark
                tagline
                Spacer()
                googleButton
                versionLabel
            }
            .padding(.horizontal, NSpace.xxl)
            .padding(.bottom, NSpace.xxl)

            if let visibleError {
                errorToast(visibleError)
            }
        }
        #if os(iOS) || os(visionOS)
        .preferredColorScheme(.dark)
        #endif
        // DEBUG: fire on any tap anywhere in the window to verify window is interactive
        .background(
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { NousLogger.info("auth", "window tap detected") }
        )
        .onAppear {
            #if os(macOS)
            // Make app frontmost immediately — without this, first click
            // goes to making the window key rather than hitting the button.
            NSApplication.shared.activate(ignoringOtherApps: true)
            #endif
            withAnimation(.timingCurve(0.23, 1.0, 0.32, 1.0, duration: 0.42)) {
                wordmarkVisible = true
            }
            haloPulse = true
        }
    }

    // MARK: - Backdrop

    private var backdrop: some View {
        ZStack {
            // Ambient breathing halo top-third. Cyan idles, brightens on sign-in.
            RadialGradient(
                colors: [
                    NSColorToken.Phos.cyan.opacity(auth.isSigningIn ? 0.32 : 0.20),
                    .clear
                ],
                center: UnitPoint(x: 0.5, y: 0.32),
                startRadius: 0,
                endRadius: haloPulse ? 540 : 460
            )
            .blur(radius: 8)
            .animation(
                .easeInOut(duration: 4.2).repeatForever(autoreverses: true),
                value: haloPulse
            )
            .animation(.easeOut(duration: 0.42), value: auth.isSigningIn)

            // Soft amber counter-glow bottom-left for warmth.
            RadialGradient(
                colors: [NSColorToken.Phos.amber.opacity(0.06), .clear],
                center: UnitPoint(x: 0.20, y: 0.95),
                startRadius: 0,
                endRadius: 360
            )
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    // MARK: - Wordmark + tagline

    private var wordmark: some View {
        Text("nous")
            .font(.system(size: 56, weight: .light, design: .serif))
            .italic()
            .foregroundStyle(NSColorToken.textPrimary)
            .tracking(-1.5)
            .opacity(wordmarkVisible ? 1.0 : 0.0)
            .offset(y: wordmarkVisible ? 0 : 12)
    }

    private var tagline: some View {
        Text("// thinking environment")
            .font(NFont.mono(11))
            .foregroundStyle(NSColorToken.textTertiary)
            .textCase(.uppercase)
            .tracking(0.30)
            .padding(.top, NSpace.sm)
            .opacity(wordmarkVisible ? 1.0 : 0.0)
    }

    // MARK: - Google button

    private var googleButton: some View {
        googleButtonLabel
            #if os(macOS)
            // On macOS SwiftUI Button machinery has persistent hit-testing issues
            // in certain window configurations. onTapGesture on the label is guaranteed
            // to fire regardless of button style, window focus state, or background layers.
            .onTapGesture { if !auth.isSigningIn { startSignIn() } }
            #else
            .overlay(Button("") { startSignIn() }
                .buttonStyle(SignInPressStyle())
                .disabled(auth.isSigningIn)
                .opacity(0))
            .onTapGesture { if !auth.isSigningIn { startSignIn() } }
            #endif
            .padding(.bottom, NSpace.md)
    }

    private var googleButtonLabel: some View {
        HStack(spacing: NSpace.md) {
            if auth.isSigningIn {
                ProgressView()
                    .controlSize(.small)
                    .tint(NSColorToken.Phos.cyan)
            } else {
                GoogleGlyph()
                    .frame(width: 18, height: 18)
            }
            Text(auth.isSigningIn ? "// opening browser…" : "continue with Google")
                .font(auth.isSigningIn ? NFont.mono(13) : NFont.body(15))
                .foregroundStyle(auth.isSigningIn
                                 ? NSColorToken.Phos.cyan
                                 : NSColorToken.textPrimary)
                .contentTransition(.opacity)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 52)
        .background(NSColorToken.inkRaised)
        .overlay(
            Rectangle()
                .stroke(
                    auth.isSigningIn
                        ? NSColorToken.Phos.cyan.opacity(0.55)
                        : NSColorToken.textGhost.opacity(0.45),
                    lineWidth: 0.5
                )
        )
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.22), value: auth.isSigningIn)
        .opacity(auth.isSigningIn ? 0.75 : 1.0)
    }

    private var versionLabel: some View {
        VStack(spacing: NSpace.xs) {
            Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1")")
                .font(NFont.mono(9))
                .foregroundStyle(NSColorToken.textGhost.opacity(0.6))
            Link("privacy policy", destination: URL(string: "https://nous.app/privacy")!)
                .font(NFont.mono(9))
                .foregroundStyle(NSColorToken.textGhost.opacity(0.45))
        }
        .padding(.top, NSpace.xs)
    }

    // MARK: - Error toast

    @ViewBuilder
    private func errorToast(_ msg: String) -> some View {
        VStack {
            Spacer()
            HStack(spacing: NSpace.sm) {
                Circle()
                    .fill(NSColorToken.Phos.orange)
                    .frame(width: 5, height: 5)
                Text(msg)
                    .font(NFont.mono(11))
                    .foregroundStyle(NSColorToken.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer()
            }
            .padding(NSpace.md)
            .background(NSColorToken.inkPaper)
            .overlay(
                Rectangle()
                    .stroke(NSColorToken.Phos.orange.opacity(0.45), lineWidth: 0.5)
            )
            .padding(.horizontal, NSpace.xl)
            .padding(.bottom, 120)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
        .ignoresSafeArea(.keyboard)
    }

    // MARK: - Logic

    private func startSignIn() {
        NousLogger.info("auth", "signIn button tapped")
        #if os(macOS)
        // Ensure app is frontmost before ASWebAuthenticationSession.start()
        // A non-key window causes the session to silently refuse to present.
        NSApplication.shared.activate(ignoringOtherApps: true)
        #endif
        #if os(iOS)
        Haptics.shared.softTick()
        #endif
        Task { @MainActor in
            do {
                _ = try await auth.signInWithGoogle()
                #if os(iOS)
                Haptics.shared.saveConfirm()
                #endif
                onSignedIn()
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                showError(msg)
                #if os(iOS)
                Haptics.shared.cancelCrash()
                #endif
            }
        }
    }

    private func showError(_ msg: String) {
        errorTask?.cancel()
        withAnimation(.easeOut(duration: 0.24)) { visibleError = msg }
        errorTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled {
                withAnimation(.easeOut(duration: 0.24)) { visibleError = nil }
            }
        }
    }
}

// MARK: - Press style

private struct SignInPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

// MARK: - Google glyph

/// Pure-SwiftUI Google "G" mark. Avoids bundling an asset; renders crisp at any
/// size. Subtle: in Kinetic Minimalism, an SF symbol would feel wrong for a
/// brand mark, but a hand-laid glyph reads as instrument.
private struct GoogleGlyph: View {
    var body: some View {
        Canvas { ctx, size in
            // Neutral white pill behind the G so brand colors read on dark backgrounds.
            let bg = CGRect(x: 0, y: 0, width: size.width, height: size.height)
            ctx.fill(Path(ellipseIn: bg), with: .color(Color.white.opacity(0.12)))

            // Authentic Google four-color G — used inside an instrument-toned chrome.
            let blue   = Color(red: 0.262, green: 0.522, blue: 0.957)
            let red    = Color(red: 0.918, green: 0.263, blue: 0.208)
            let yellow = Color(red: 0.984, green: 0.737, blue: 0.020)
            let green  = Color(red: 0.204, green: 0.659, blue: 0.325)

            let r = min(size.width, size.height) / 2
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let outer = CGRect(x: center.x - r, y: center.y - r, width: r*2, height: r*2)
            let inner = outer.insetBy(dx: r * 0.42, dy: r * 0.42)

            // Four arcs — start angles in degrees from 12 o'clock going CW.
            let segments: [(start: Angle, sweep: Angle, color: Color)] = [
                (.degrees(-90), .degrees(90), red),     // top-right
                (.degrees(0),   .degrees(90), yellow),  // bottom-right
                (.degrees(90),  .degrees(90), green),   // bottom-left
                (.degrees(180), .degrees(90), blue),    // top-left
            ]
            for seg in segments {
                var p = Path()
                p.addArc(center: center, radius: r,
                         startAngle: seg.start, endAngle: seg.start + seg.sweep, clockwise: false)
                p.addArc(center: center, radius: r * 0.58,
                         startAngle: seg.start + seg.sweep, endAngle: seg.start, clockwise: true)
                p.closeSubpath()
                ctx.fill(p, with: .color(seg.color))
            }

            // The horizontal "G bar" — flat segment cutting into the right side.
            let bar = CGRect(
                x: center.x,
                y: center.y - r * 0.10,
                width: r * 0.95,
                height: r * 0.20
            )
            ctx.fill(Path(bar), with: .color(blue))

            // Punch a clean inner circle hole so center stays open.
            ctx.blendMode = .destinationOut
            ctx.fill(Path(ellipseIn: inner), with: .color(.black))
        }
    }
}
