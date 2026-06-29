import SwiftUI

struct TasksSheet: View {
    let store: AtomStore
    let onDismiss: () -> Void
    let onPickAtom: (AtomSnapshot) -> Void

    var body: some View {
        ZStack(alignment: .top) {
            NSColorToken.inkPaper.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                header
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: NSpace.xxl) {
                        section("today", atoms: bucket(.today))
                        section("this week", atoms: bucket(.week))
                        section("someday", atoms: bucket(.someday))
                        section("no deadline", atoms: bucket(.none))
                    }
                    .padding(.horizontal, NSpace.xl)
                    .padding(.vertical, NSpace.xl)
                }
            }
        }
    }

    private var header: some View {
        HStack {
            Text("tasks")
                .font(NFont.dayHeader(28))
                .foregroundStyle(NSColorToken.textPrimary)
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "chevron.right")
                    .foregroundStyle(NSColorToken.textSecondary)
                    .padding(NSpace.md)
            }
        }
        .padding(.horizontal, NSpace.xl)
        .padding(.top, NSpace.xxl)
        .padding(.bottom, NSpace.md)
    }

    @ViewBuilder private func section(_ title: String, atoms: [AtomSnapshot]) -> some View {
        VStack(alignment: .leading, spacing: NSpace.md) {
            Text(title)
                .font(NFont.mono(11))
                .foregroundStyle(NSColorToken.textSecondary)
                .textCase(.uppercase)
                .tracking(0.10)
            if atoms.isEmpty {
                Text("\(title) — clear.")
                    .font(NFont.mono(12))
                    .foregroundStyle(NSColorToken.textGhost)
            } else {
                ForEach(atoms) { a in
                    taskRow(a)
                }
            }
        }
    }

    private func taskRow(_ a: AtomSnapshot) -> some View {
        HStack(alignment: .top, spacing: NSpace.md) {
            Button {
                store.toggleTask(id: a.id)
                Haptics.shared.softTick()
            } label: {
                ZStack {
                    Circle()
                        .strokeBorder(
                            (a.taskDone ?? false) ? NSColorToken.textGhost : NSColorToken.Phos.green,
                            lineWidth: 1
                        )
                    if a.taskDone ?? false {
                        Circle()
                            .fill(NSColorToken.Phos.green.opacity(0.25))
                            .padding(3)
                    }
                }
                .frame(width: 14, height: 14)
                .animation(.spring(response: 0.3, dampingFraction: 0.65), value: a.taskDone)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: NSpace.xs) {
                    if a.priority == .high {
                        Image(systemName: "exclamationmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(NSColorToken.Phos.orange)
                            .accessibilityLabel("High priority")
                    }
                    Text(a.oneLiner)
                        .font(NFont.body(15))
                        .foregroundStyle((a.taskDone ?? false) ? NSColorToken.textTertiary : NSColorToken.textPrimary)
                        .strikethrough(a.taskDone ?? false)
                        .lineLimit(2)
                }
                if let due = a.dueAt {
                    Text(dueFmt(due))
                        .font(NFont.mono(10))
                        .foregroundStyle(NSColorToken.textTertiary)
                }
            }
            Spacer()
            priorityMenu(for: a)
            dueMenu(for: a)
        }
        .contentShape(Rectangle())
        .onTapGesture { onPickAtom(a) }
    }

    private func dueMenu(for atom: AtomSnapshot) -> some View {
        Menu {
            Button("today") { setDue(for: atom.id, days: 0) }
            Button("tomorrow") { setDue(for: atom.id, days: 1) }
            Button("next week") { setDue(for: atom.id, days: 7) }
            Button("someday") { setDue(for: atom.id, days: 14) }
            if atom.dueAt != nil {
                Button("clear deadline") { setDue(atom.id, to: nil) }
            }
        } label: {
            Text(atom.dueAt.map(dueChipText) ?? "set date")
                .font(NFont.mono(10))
                .foregroundStyle(atom.dueAt == nil ? NSColorToken.textGhost : NSColorToken.Phos.amber.opacity(0.85))
                .padding(.horizontal, NSpace.sm)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(atom.dueAt == nil ? NSColorToken.inkMembrane : NSColorToken.Phos.amber.opacity(0.10))
                )
                .overlay(
                    Capsule().stroke(NSColorToken.textGhost.opacity(0.18), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
    }

    private func priorityMenu(for atom: AtomSnapshot) -> some View {
        Menu {
            Button("high")   { setPriority(atom.id, .high) }
            Button("normal") { setPriority(atom.id, .normal) }
            Button("low")    { setPriority(atom.id, .low) }
        } label: {
            Image(systemName: atom.priority == .high ? "flag.fill" : "flag")
                .font(.system(size: 10))
                .foregroundStyle(priorityColor(atom.priority))
                .padding(.horizontal, NSpace.sm)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Set priority")
    }

    private func priorityColor(_ p: TaskPriority?) -> Color {
        switch p {
        case .high: NSColorToken.Phos.orange
        case .low:  NSColorToken.textGhost
        default:    NSColorToken.textGhost.opacity(0.5)
        }
    }

    private func setPriority(_ id: UUID, _ p: TaskPriority) {
        store.setPriority(id: id, to: p)
        Haptics.shared.softTick()
    }

    enum Bucket { case today, week, someday, none }
    private func bucket(_ b: Bucket) -> [AtomSnapshot] {
        let cal = Calendar.current; let now = Date()
        return store.taskAtoms.filter { a in
            switch b {
            case .none: return a.dueAt == nil
            case .today:
                guard let d = a.dueAt else { return false }
                return cal.isDate(d, inSameDayAs: now)
            case .week:
                guard let d = a.dueAt else { return false }
                if cal.isDate(d, inSameDayAs: now) { return false }
                let wkLater = cal.date(byAdding: .day, value: 7, to: now) ?? now
                return d > now && d <= wkLater
            case .someday:
                guard let d = a.dueAt else { return false }
                let wkLater = cal.date(byAdding: .day, value: 7, to: now) ?? now
                return d > wkLater
            }
        }
        // High priority floats up within each bucket; then by due date.
        .sorted { lhs, rhs in
            let lr = lhs.priority?.rank ?? 1, rr = rhs.priority?.rank ?? 1
            if lr != rr { return lr > rr }
            return (lhs.dueAt ?? .distantFuture) < (rhs.dueAt ?? .distantFuture)
        }
    }

    private func dueFmt(_ d: Date) -> String {
        let df = DateFormatter(); df.dateFormat = "MMM d"
        return df.string(from: d).lowercased()
    }

    private func dueChipText(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "today" }
        if cal.isDateInTomorrow(date) { return "tomorrow" }
        return dueFmt(date)
    }

    private func setDue(for id: UUID, days: Int) {
        let cal = Calendar.current
        let base = cal.startOfDay(for: .now)
        let date = cal.date(byAdding: .day, value: days, to: base) ?? base
        setDue(id, to: date)
    }

    private func setDue(_ id: UUID, to date: Date?) {
        store.setDue(id: id, to: date)
        Haptics.shared.softTick()
    }
}
