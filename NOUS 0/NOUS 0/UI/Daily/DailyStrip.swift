import SwiftUI

/// Three-card horizontal strip that sits above the Stream when no filter is
/// active. Cards: On This Day · Random · Slow Mode.
///
/// Visual rhythm:
///   - Each card 240×96, inkRaised w/ hairline phosphor border
///   - Mono micro-label up top in textTertiary (`// on this day`), body in textPrimary
///   - Press: 0.97 scale + opacity 0.85, 100ms ease-out (Emil's responsive button rule)
///   - Refresh button (random card) spins 360° on tap (single revolution, 380ms easeInOut)
///   - "On this day" gets violet hairline (memory phosphor); "Random" cyan; "Slow" amber
///
/// Cards collapse if their content is unavailable: no atom from this day in any
/// past year → On This Day card is hidden (no empty state, the absence of card =
/// the empty state).
struct DailyStrip: View {
    let store: AtomStore
    let onPickAtom: (AtomSnapshot) -> Void

    @State private var picks: DailyDigest.Picks?
    @State private var randomSpinAngle: Double = 0

    var body: some View {
        let picks = picks ?? DailyDigest.compute(from: store.ordered)
        let hasOnThisDay = picks.onThisDay != nil
        let hasRandom = picks.random != nil

        if !hasOnThisDay && !hasRandom && store.ordered.isEmpty {
            // Vault empty — let the Stream's own empty state speak.
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: NSpace.sm) {
                Text("// daily")
                    .font(NFont.mono(10))
                    .foregroundStyle(NSColorToken.textTertiary)
                    .padding(.horizontal, NSpace.xs)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: NSpace.md) {
                        if let atom = picks.onThisDay {
                            onThisDayCard(atom)
                        }
                        if let atom = picks.random {
                            randomCard(atom)
                        }
                    }
                    .padding(.horizontal, NSpace.xs)
                }
            }
            .padding(.bottom, NSpace.lg)
            .task(id: dayKey()) {
                // Recompute when the day changes (or on first appearance).
                self.picks = DailyDigest.compute(from: store.ordered)
            }
        }
    }

    // MARK: - On This Day

    private func onThisDayCard(_ atom: AtomSnapshot) -> some View {
        let years = yearsAgo(atom.createdAt)
        return cardShell(
            label: "// on this day · \(years)y ago",
            phosphor: NSColorToken.Phos.violet,
            primary: atom.oneLiner,
            secondary: shortDate(atom.createdAt),
            secondaryColor: NSColorToken.textTertiary,
            action: {
                Haptics.shared.softTick()
                onPickAtom(atom)
            }
        )
    }

    // MARK: - Random

    @ViewBuilder
    private func randomCard(_ atom: AtomSnapshot) -> some View {
        Button {
            // Tap = open picked atom.
            Haptics.shared.softTick()
            onPickAtom(atom)
        } label: {
            cardBody(
                label: "// random",
                labelTrailing: refreshGlyph,
                phosphor: NSColorToken.Phos.cyan,
                primary: atom.oneLiner,
                secondary: shortDate(atom.createdAt),
                secondaryColor: NSColorToken.textTertiary
            )
        }
        .buttonStyle(CardPressStyle())
    }

    private var refreshGlyph: some View {
        Button {
            // Re-roll just the random card. Spin glyph for feedback.
            Haptics.shared.softTick()
            withAnimation(.timingCurve(0.32, 0.72, 0.0, 1.0, duration: 0.38)) {
                randomSpinAngle += 360
            }
            // Re-pick by recomputing entire digest (cheap: O(n)).
            picks = DailyDigest.compute(from: store.ordered)
        } label: {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 10, weight: .regular))
                .foregroundStyle(NSColorToken.textTertiary)
                .rotationEffect(.degrees(randomSpinAngle))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Card chrome

    private func cardShell(
        label: String,
        phosphor: Color,
        primary: String,
        secondary: String,
        secondaryColor: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            cardBody(
                label: label,
                labelTrailing: nil as EmptyView?,
                phosphor: phosphor,
                primary: primary,
                secondary: secondary,
                secondaryColor: secondaryColor
            )
        }
        .buttonStyle(CardPressStyle())
    }

    private func cardBody<Trailing: View>(
        label: String,
        labelTrailing: Trailing?,
        phosphor: Color,
        primary: String,
        secondary: String,
        secondaryColor: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: NSpace.xs) {
            HStack(spacing: 0) {
                Text(label)
                    .font(NFont.mono(9))
                    .foregroundStyle(phosphor.opacity(0.85))
                    .textCase(.uppercase)
                    .tracking(0.10)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let labelTrailing { labelTrailing }
            }
            Text(primary)
                .font(NFont.body(15))
                .foregroundStyle(NSColorToken.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Text(secondary)
                .font(NFont.mono(9))
                .foregroundStyle(secondaryColor)
        }
        .padding(.vertical, NSpace.sm)
        .padding(.horizontal, NSpace.xs)
        .frame(width: 240, height: 104, alignment: .topLeading)
        // Flat — no fill, no stroke. Typography + phosphor label carry the
        // card. A single hairline rule at the bottom marks the footer baseline
        // (like a magazine column dividing rule), cued to the phosphor.
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(phosphor.opacity(0.35))
                .frame(height: 0.5)
        }
    }

    // MARK: - Helpers

    private func yearsAgo(_ d: Date) -> Int {
        max(1, Calendar.current.dateComponents([.year], from: d, to: .now).year ?? 1)
    }

    private func shortDate(_ d: Date) -> String {
        d.formatted(.dateTime.month(.abbreviated).day().year())
            .lowercased()
    }

    /// Stable per-day key so SwiftUI re-runs `.task(id:)` exactly when the
    /// calendar day rolls over (and on first appearance).
    private func dayKey() -> Int {
        let day = Calendar.current.startOfDay(for: .now)
        return Int(day.timeIntervalSinceReferenceDate)
    }
}

/// Card press style: scale 0.97 + opacity dip. 120ms ease-out keeps the touch
/// feeling immediate while leaving room for the eye to register the recoil.
private struct CardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.88 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
