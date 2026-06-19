import SwiftUI

// ─── DailyBriefingView ──────────────────────────────────────────────────────
//
// The "it briefs you" home moment. A calm, editorial read of the day:
//   - A dated header in the heavy compressed display register (wordmark vibe).
//   - Each non-empty section as a titled group of tappable rows
//     (phosphor dot + one-liner + due/age/kind meta).
//   - Empty sections are hidden entirely (absence = empty state).
//
// Pure presentation: data comes from DailyBriefingVM, atom-opening is delegated
// to the host via `onPickAtom`.

struct DailyBriefingView: View {
    @State var vm: DailyBriefingVM
    /// Host opens the tapped atom. Pushback prompt-only rows pass through only
    /// when they carry an anchor atom.
    let onPickAtom: (AtomSnapshot) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
                .overlay(NSColorToken.textGhost.opacity(0.12))

            if vm.sections.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: NSpace.xl) {
                        ForEach(vm.sections) { section in
                            sectionView(section)
                        }
                    }
                    .padding(.horizontal, NSpace.xl)
                    .padding(.top, NSpace.xl)
                    .padding(.bottom, NSpace.xxxl)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(minWidth: 460, idealWidth: 520, minHeight: 460, idealHeight: 600)
        .background(NSColorToken.inkVoid)
        .preferredColorScheme(.dark)
        .task { vm.refresh() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: NSpace.md) {
            VStack(alignment: .leading, spacing: NSpace.xs) {
                Text("// briefing")
                    .font(NFont.mono(10))
                    .foregroundStyle(NSColorToken.textTertiary)
                    .textCase(.uppercase)
                    .tracking(0.12)
                Text(Self.dateline)
                    .font(NFont.dayHeader(34))
                    .foregroundStyle(NSColorToken.textPrimary)
                    .textCase(.uppercase)
            }
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(NSColorToken.textGhost)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("close briefing")
        }
        .padding(.horizontal, NSpace.xl)
        .padding(.top, NSpace.xl)
        .padding(.bottom, NSpace.lg)
    }

    private static var dateline: String {
        Date.now.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
            .lowercased()
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: NSpace.md) {
            Image(systemName: "moon.stars")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(NSColorToken.textGhost)
            Text("nothing pressing today")
                .font(NFont.body(15))
                .foregroundStyle(NSColorToken.textSecondary)
            Text("// no due tasks, memories, or open threads")
                .font(NFont.mono(10))
                .foregroundStyle(NSColorToken.textGhost)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(NSpace.xxxl)
    }

    // MARK: - Section

    @ViewBuilder
    private func sectionView(_ section: DailyBriefingVM.BriefingSection) -> some View {
        let accent = Self.color(for: section.phosphor)
        VStack(alignment: .leading, spacing: NSpace.sm) {
            // Section header — phosphor glyph + mono label + hairline rule.
            HStack(spacing: NSpace.sm) {
                Image(systemName: section.systemImage)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(accent.opacity(0.9))
                    .frame(width: 14)
                Text("// \(section.title)")
                    .font(NFont.monoSmall(11))
                    .foregroundStyle(NSColorToken.textTertiary)
                    .textCase(.uppercase)
                    .tracking(0.10)
                Text("\(section.items.count)")
                    .font(NFont.monoSmall(10))
                    .foregroundStyle(NSColorToken.textGhost)
                    .monospacedDigit()
                Spacer(minLength: 0)
            }
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(accent.opacity(0.22))
                    .frame(height: 0.5)
                    .offset(y: 6)
            }
            .padding(.bottom, NSpace.xs)

            ForEach(section.items) { item in
                row(item, accent: accent)
            }
        }
    }

    // MARK: - Row

    @ViewBuilder
    private func row(_ item: DailyBriefingVM.BriefingItem, accent: Color) -> some View {
        let isTappable = item.atom != nil
        Button {
            guard let atom = item.atom else { return }
            onPickAtom(atom)
        } label: {
            HStack(alignment: .top, spacing: NSpace.sm) {
                // Type dot — uses the atom's own phosphor when present, else the
                // section accent (prompt-only pushback rows).
                Circle()
                    .fill(item.atom?.type.phosphor ?? accent)
                    .frame(width: 6, height: 6)
                    .padding(.top, 6)

                Text(item.headline)
                    .font(NFont.body(14))
                    .foregroundStyle(isTappable
                        ? NSColorToken.textSecondary
                        : NSColorToken.textTertiary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let meta = item.meta {
                    Text(meta)
                        .font(NFont.mono(9))
                        .foregroundStyle(metaColor(for: meta))
                        .monospacedDigit()
                        .padding(.top, 2)
                        .layoutPriority(1)
                }
            }
            .padding(.vertical, NSpace.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(BriefingRowStyle(isTappable: isTappable))
        .disabled(!isTappable)
    }

    /// Overdue meta reads in the alert phosphor; everything else stays ghosted.
    private func metaColor(for meta: String) -> Color {
        meta.hasPrefix("overdue")
            ? NSColorToken.Phos.orange.opacity(0.85)
            : NSColorToken.textGhost
    }

    // MARK: - Phosphor mapping

    private static func color(for accent: DailyBriefingVM.PhosphorAccent) -> Color {
        switch accent {
        case .cyan:   NSColorToken.Phos.cyan
        case .green:  NSColorToken.Phos.green
        case .amber:  NSColorToken.Phos.amber
        case .blue:   NSColorToken.Phos.blue
        case .orange: NSColorToken.Phos.orange
        case .violet: NSColorToken.Phos.violet
        }
    }
}

// MARK: - Row press style

/// Subtle row affordance: a faint raised wash + slight nudge on press, so the
/// briefing reads as a composed page rather than a clickable list.
private struct BriefingRowStyle: ButtonStyle {
    let isTappable: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, NSpace.sm)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(configuration.isPressed && isTappable
                        ? NSColorToken.inkRaised.opacity(0.6)
                        : Color.clear)
            )
            .opacity(configuration.isPressed && isTappable ? 0.9 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
