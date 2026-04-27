import SwiftUI

/// Single-atom-at-a-time reader. Strips chrome, leaves just the body + a
/// minimal counter and gesture affordances. Designed for "I will be present
/// with each thought before moving on."
///
/// Interaction:
///   - Swipe left: next atom (with momentum dismiss threshold)
///   - Swipe right: previous atom
///   - Swipe down: exit slow mode
///   - Tap atom body: enter detail (full edit / link surfaces)
///   - Cyan progress hairline at bottom shows position in the stack
///
/// Motion:
///   - Atom-to-atom transition uses asymmetric horizontal slide + opacity, w/
///     blur(2) on the outgoing atom (Emil's "blur masks imperfect transitions")
///   - 320ms cubic-out for the slide; opacity fades 220ms ease-out
///   - Counter morphs via numeric content transition (iOS 17)
///   - Header "// slow read" pulses softly once on enter so user knows mode changed
struct SlowReadView: View {
    let store: AtomStore
    let onClose: () -> Void
    /// Optional: when set, opens detail for the picked atom. Gives users an
    /// escape hatch to the full surface w/o exiting slow mode entirely (caller
    /// can choose to dismiss SlowReadView when an atom is picked).
    let onPickAtom: (AtomSnapshot) -> Void

    /// Stable shuffled order — re-shuffles only on view re-creation, never
    /// during a session, so navigation is predictable.
    @State private var order: [AtomSnapshot] = []
    @State private var index: Int = 0

    @State private var dragX: CGFloat = 0
    @State private var dragY: CGFloat = 0
    @State private var dragStart: Date?
    @State private var enteringPulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            backdrop

            if let atom = currentAtom {
                content(atom)
                    .id(atom.id) // re-run transition per atom
                    .transition(slideTransition)
            } else {
                emptyState
            }

            VStack {
                header
                Spacer()
                progressBar
            }
        }
        .background(NSColorToken.inkVoid.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .gesture(swipeGesture)
        .onAppear {
            order = store.ordered.filter { !$0.isDeleted }
            // Briefly pulse the header so users feel the mode change.
            withAnimation(.easeOut(duration: 0.4)) { enteringPulse = true }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 600_000_000)
                withAnimation(.easeOut(duration: 0.6)) { enteringPulse = false }
            }
        }
    }

    // MARK: - Backdrop

    /// Amber phosphor halo — slow mode's signature color. Same diffused-aura
    /// rule as AI states: sit behind the body, never compete.
    private var backdrop: some View {
        ZStack {
            RadialGradient(
                colors: [NSColorToken.Phos.amber.opacity(0.14), .clear],
                center: UnitPoint(x: 0.5, y: 0.18),
                startRadius: 0,
                endRadius: 520
            )
            RadialGradient(
                colors: [NSColorToken.Phos.amber.opacity(0.06), .clear],
                center: UnitPoint(x: 0.5, y: 1.05),
                startRadius: 0,
                endRadius: 360
            )
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: NSpace.md) {
            Text("// slow read")
                .font(NFont.mono(11))
                .foregroundStyle(enteringPulse
                                 ? NSColorToken.Phos.amber
                                 : NSColorToken.textTertiary)
                .textCase(.uppercase)
                .tracking(0.10)
            Spacer()
            // Counter w/ numeric content transition
            Text("\(index + 1) / \(order.count)")
                .font(NFont.mono(10))
                .foregroundStyle(NSColorToken.textGhost)
                .monospacedDigit()
                .contentTransition(.numericText())
            Button(action: closeWithHaptic) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(NSColorToken.textSecondary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("exit slow mode")
        }
        .padding(.horizontal, NSpace.xl)
        .padding(.top, NSpace.lg)
    }

    // MARK: - Content

    @ViewBuilder
    private func content(_ atom: AtomSnapshot) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NSpace.lg) {
                // Atom-type dot + label as a small header
                HStack(spacing: NSpace.xs) {
                    AtomDot(type: atom.type, size: 8)
                    Text(atom.type.label)
                        .font(NFont.mono(10))
                        .foregroundStyle(NSColorToken.textTertiary)
                        .textCase(.uppercase)
                        .tracking(0.10)
                    Spacer()
                    Text(longDate(atom.createdAt))
                        .font(NFont.mono(10))
                        .foregroundStyle(NSColorToken.textGhost)
                }
                MarkdownView(
                    raw: atom.displayContent,
                    store: store,
                    atomID: atom.id,
                    onPickAtom: { picked in
                        Haptics.shared.softTick()
                        onPickAtom(picked)
                    }
                )
                .onTapGesture {
                    // Tap the body to escape into full detail.
                    Haptics.shared.softTick()
                    onPickAtom(atom)
                }
            }
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, NSpace.xxl)
            .padding(.top, 80)
            .padding(.bottom, 120)
        }
        .scrollIndicators(.hidden)
        // Translate w/ drag for visceral connection to gesture.
        .offset(x: reduceMotion ? 0 : dragX, y: reduceMotion ? 0 : (dragY > 0 ? dragY * 0.5 : 0))
        .opacity(opacityForDrag)
    }

    private var opacityForDrag: Double {
        let total = abs(dragX) + max(0, dragY)
        return max(0.4, 1.0 - Double(total) / 600.0)
    }

    // MARK: - Empty

    private var emptyState: some View {
        VStack(spacing: NSpace.md) {
            Text("// nothing to read")
                .font(NFont.mono(12))
                .foregroundStyle(NSColorToken.textGhost)
            Text("the vault is empty.")
                .font(NFont.body(14))
                .foregroundStyle(NSColorToken.textSecondary)
        }
    }

    // MARK: - Progress hairline

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(NSColorToken.textGhost.opacity(0.18))
                    .frame(height: 1)
                Rectangle()
                    .fill(NSColorToken.Phos.amber.opacity(0.85))
                    .frame(width: progressWidth(geo.size.width), height: 1)
                    .animation(.timingCurve(0.23, 1.0, 0.32, 1.0, duration: 0.32), value: index)
            }
            .frame(height: 1)
        }
        .frame(height: 1)
        .padding(.horizontal, NSpace.xl)
        .padding(.bottom, NSpace.xl)
    }

    private func progressWidth(_ total: CGFloat) -> CGFloat {
        guard !order.isEmpty else { return 0 }
        return total * CGFloat(index + 1) / CGFloat(order.count)
    }

    // MARK: - Gesture

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { g in
                if dragStart == nil { dragStart = .now }
                dragX = g.translation.width
                dragY = max(-30, g.translation.height) // resist upward drag
            }
            .onEnded { g in
                let dx = g.translation.width
                let dy = g.translation.height
                let elapsed = Date().timeIntervalSince(dragStart ?? .now)
                let velocityX = abs(dx) / max(elapsed, 0.001)

                dragStart = nil
                // Down swipe = exit
                if dy > 100 && abs(dy) > abs(dx) {
                    closeWithHaptic()
                    return
                }
                // Horizontal commit: distance OR velocity
                let committed = abs(dx) > 80 || velocityX > 700
                if committed {
                    if dx < 0 { advance() } else { rewind() }
                }
                // Spring back to zero regardless.
                withAnimation(.timingCurve(0.32, 0.72, 0, 1.0, duration: 0.32)) {
                    dragX = 0
                    dragY = 0
                }
            }
    }

    // MARK: - Navigation

    private var currentAtom: AtomSnapshot? {
        guard !order.isEmpty, index >= 0, index < order.count else { return nil }
        return order[index]
    }

    private func advance() {
        guard index + 1 < order.count else {
            // End of stack — gentle bump haptic, no wrap.
            Haptics.shared.softTick()
            return
        }
        Haptics.shared.softTick()
        withAnimation(reduceMotion ? .none : .timingCurve(0.23, 1.0, 0.32, 1.0, duration: 0.32)) {
            index += 1
        }
    }

    private func rewind() {
        guard index > 0 else {
            Haptics.shared.softTick()
            return
        }
        Haptics.shared.softTick()
        withAnimation(reduceMotion ? .none : .timingCurve(0.23, 1.0, 0.32, 1.0, duration: 0.32)) {
            index -= 1
        }
    }

    private func closeWithHaptic() {
        Haptics.shared.heavyThud()
        onClose()
    }

    // MARK: - Transition

    /// Asymmetric slide: incoming from the trailing edge w/ slight blur to mask
    /// the swap (Emil's "blur masks imperfect transitions"). Outgoing fades out
    /// faster than incoming fades in for that "settling into focus" feel.
    private var slideTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .trailing)
                .combined(with: .opacity)
                .combined(with: .modifier(active: BlurModifier(radius: 4),
                                          identity: BlurModifier(radius: 0))),
            removal: .move(edge: .leading)
                .combined(with: .opacity)
        )
    }

    // MARK: - Helpers

    private func longDate(_ d: Date) -> String {
        d.formatted(.dateTime.month(.wide).day().year().hour().minute())
            .lowercased()
    }
}

/// Modifier we can interpolate via .transition(.modifier(active:identity:)).
/// SwiftUI doesn't support animating .blur via .transition directly.
private struct BlurModifier: ViewModifier {
    let radius: CGFloat
    func body(content: Content) -> some View { content.blur(radius: radius) }
}
