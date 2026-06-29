import SwiftUI

/// Proactive "what's due" strip for the top of the iOS stream — the actionable
/// half of the daily briefing that, until now, only existed on macOS. Shows open
/// tasks that are overdue or due today, soonest first; hides itself entirely when
/// there's nothing due (absence = empty state). Tap a row to open the task.
struct DueTodayBanner: View {
    let store: AtomStore
    var onPick: (AtomSnapshot) -> Void

    private var due: [AtomSnapshot] {
        let cal = Calendar.current
        let endOfToday = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: .now)) ?? .now
        return store.taskAtoms
            .filter { !$0.isDeleted && !($0.taskDone ?? false) && ($0.dueAt.map { $0 < endOfToday } ?? false) }
            .sorted { ($0.dueAt ?? .now) < ($1.dueAt ?? .now) }
    }

    var body: some View {
        let items = due
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: NSpace.sm) {
                HStack(spacing: NSpace.xs) {
                    Text("// due")
                        .font(NFont.mono(10))
                        .foregroundStyle(NSColorToken.textTertiary)
                    if items.count > 3 {
                        Text("· \(items.count)")
                            .font(NFont.monoSmall(10))
                            .foregroundStyle(NSColorToken.textGhostDim)
                            .monospacedDigit()
                    }
                }
                .padding(.horizontal, NSpace.xs)

                VStack(spacing: 0) {
                    ForEach(items.prefix(3)) { atom in
                        Button { onPick(atom) } label: { row(atom) }
                            .buttonStyle(.plain)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(NSColorToken.inkRaised.opacity(0.55))
                        .overlay(RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(NSColorToken.Phos.green.opacity(0.18), lineWidth: 0.5))
                )
            }
        }
    }

    private func row(_ atom: AtomSnapshot) -> some View {
        HStack(spacing: NSpace.sm) {
            Circle().fill(NSColorToken.Phos.green).frame(width: 5, height: 5)
            Text(atom.oneLiner)
                .font(NFont.mono(12))
                .foregroundStyle(NSColorToken.textSecondary)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: NSpace.sm)
            Text(meta(for: atom.dueAt))
                .font(NFont.monoSmall(10))
                .foregroundStyle(isOverdue(atom.dueAt) ? NSColorToken.Phos.orange.opacity(0.85)
                                                       : NSColorToken.textGhostDim)
                .monospacedDigit()
        }
        .padding(.horizontal, NSpace.md)
        .padding(.vertical, NSpace.sm)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Due task: \(atom.oneLiner), \(meta(for: atom.dueAt))")
    }

    private func isOverdue(_ due: Date?) -> Bool {
        guard let due else { return false }
        return due < Calendar.current.startOfDay(for: .now)
    }

    private func meta(for due: Date?) -> String {
        guard let due else { return "" }
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: due),
                                      to: cal.startOfDay(for: .now)).day ?? 0
        return days > 0 ? "overdue \(days)d" : "today"
    }
}
