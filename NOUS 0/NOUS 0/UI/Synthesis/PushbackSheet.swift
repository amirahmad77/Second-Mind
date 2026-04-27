import SwiftUI

/// Pushback surface — appears when user taps the badge near the Orb.
/// Stack of "have you considered" cards. Each card shows the prompt,
/// the kind tag, and a chip per cited atom (tap to open).
/// Per PRD: "never auto-edits; only suggests."
struct PushbackSheet: View {
    let store: AtomStore
    let vm: PushbackVM
    let onDismiss: () -> Void
    let onPickAtom: (AtomSnapshot) -> Void

    var body: some View {
        ZStack(alignment: .top) {
            backdrop

            VStack(spacing: 0) {
                header
                Divider()
                    .frame(height: 0.5)
                    .overlay(NSColorToken.textGhost.opacity(0.35))
                content
            }
        }
        .background(NSColorToken.inkVoid.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    // MARK: Backdrop — violet for "consider" energy

    private var backdrop: some View {
        RadialGradient(
            colors: [NSColorToken.Phos.violet.opacity(0.18), .clear],
            center: UnitPoint(x: 0.18, y: 0.12),
            startRadius: 0,
            endRadius: 480
        )
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private var header: some View {
        HStack(spacing: NSpace.md) {
            Text("// pushback")
                .font(NFont.mono(11))
                .foregroundStyle(NSColorToken.textTertiary)
                .textCase(.uppercase)
                .tracking(0.10)
            Text("· things to reconsider")
                .font(NFont.mono(10))
                .foregroundStyle(NSColorToken.textGhost)
            Spacer()
            if vm.isFetching {
                Text("// scanning")
                    .font(NFont.mono(10))
                    .foregroundStyle(NSColorToken.Phos.violet.opacity(0.7))
            } else {
                Button(action: { vm.refresh() }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(NSColorToken.textTertiary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Button(action: onDismiss) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(NSColorToken.textSecondary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, NSpace.xl)
        .padding(.top, NSpace.lg)
        .padding(.bottom, NSpace.md)
    }

    @ViewBuilder private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NSpace.lg) {
                if vm.visibleItems.isEmpty {
                    emptyState
                } else {
                    ForEach(vm.visibleItems) { item in
                        card(item)
                    }
                }
            }
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, NSpace.xl)
            .padding(.top, NSpace.lg)
            .padding(.bottom, NSpace.xxl)
        }
        .scrollIndicators(.hidden)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: NSpace.sm) {
            if vm.isFetching {
                Text("// scanning your recent atoms…")
                    .font(NFont.mono(11))
                    .foregroundStyle(NSColorToken.Phos.violet.opacity(0.7))
            } else if let err = vm.lastError {
                Text("// could not scan")
                    .font(NFont.mono(11))
                    .foregroundStyle(NSColorToken.Phos.orange)
                Text(err)
                    .font(NFont.body(13))
                    .foregroundStyle(NSColorToken.textSecondary)
            } else {
                Text("// no pushback")
                    .font(NFont.mono(11))
                    .foregroundStyle(NSColorToken.textGhost)
                Text("nothing worth flagging in your recent atoms.")
                    .font(NFont.body(14))
                    .foregroundStyle(NSColorToken.textSecondary)
            }
        }
    }

    private func card(_ item: NousBackendClient.PushbackItem) -> some View {
        VStack(alignment: .leading, spacing: NSpace.md) {
            HStack(spacing: NSpace.sm) {
                kindChip(item.kind)
                Spacer()
                Text(String(format: "%.0f%% confident", item.confidence * 100))
                    .font(NFont.mono(9))
                    .foregroundStyle(NSColorToken.textGhost)
                // Tap = soft snooze 24h (softTick per haptic vocabulary).
                // Long-press = dismiss forever (heavyThud — destructive intent).
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(NSColorToken.textGhost)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        Haptics.shared.softTick()
                        withAnimation(.nEaseOutQuint) { vm.snooze(item) }
                    }
                    .onLongPressGesture(minimumDuration: 0.45) {
                        Haptics.shared.heavyThud()
                        withAnimation(.nEaseOutQuint) { vm.dismissForever(item) }
                    }
                    .accessibilityLabel("dismiss")
                    .accessibilityHint("tap to snooze 24 hours, long-press to dismiss forever")
            }
            Text(item.prompt)
                .font(NFont.body(16))
                .foregroundStyle(NSColorToken.textPrimary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            if !item.atom_ids.isEmpty {
                Divider()
                    .frame(height: 0.5)
                    .overlay(NSColorToken.textGhost.opacity(0.25))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: NSpace.sm) {
                        ForEach(item.atom_ids, id: \.self) { aid in
                            atomRef(aid)
                        }
                    }
                }
            }
        }
        .padding(NSpace.lg)
        .background(NSColorToken.inkRaised)
        .overlay(Rectangle().stroke(NSColorToken.textGhost.opacity(0.2), lineWidth: 0.5))
    }

    private func kindChip(_ kind: String) -> some View {
        Text(kind)
            .font(NFont.mono(9))
            .foregroundStyle(kindColor(kind))
            .textCase(.uppercase)
            .tracking(0.10)
            .padding(.horizontal, NSpace.sm)
            .padding(.vertical, 3)
            .overlay(Rectangle().stroke(kindColor(kind).opacity(0.5), lineWidth: 0.5))
    }

    private func kindColor(_ kind: String) -> Color {
        switch kind {
        case "contradiction": NSColorToken.Phos.orange
        case "gap":           NSColorToken.Phos.amber
        case "question":      NSColorToken.Phos.cyan
        case "assumption":    NSColorToken.Phos.violet
        case "thread":        NSColorToken.Phos.green
        default:              NSColorToken.textTertiary
        }
    }

    @ViewBuilder private func atomRef(_ aid: UUID) -> some View {
        if let atom = store.atoms[aid] {
            Button(action: { onPickAtom(atom) }) {
                HStack(spacing: NSpace.xs) {
                    AtomDot(type: atom.type, size: 5)
                    Text(atom.oneLiner)
                        .font(NFont.body(12))
                        .foregroundStyle(NSColorToken.textSecondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, NSpace.sm)
                .padding(.vertical, 4)
                .background(NSColorToken.inkPaper)
                .overlay(Rectangle().stroke(NSColorToken.textGhost.opacity(0.2), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
        }
    }
}
