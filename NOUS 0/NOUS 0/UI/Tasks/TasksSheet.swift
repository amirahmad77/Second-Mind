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
                Image(systemName: (a.taskDone ?? false) ? "checkmark.square" : "square")
                    .foregroundStyle((a.taskDone ?? false) ? NSColorToken.Phos.green : NSColorToken.textTertiary)
                    .font(.system(size: 16, weight: .regular))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(a.oneLiner)
                    .font(NFont.body(15))
                    .foregroundStyle((a.taskDone ?? false) ? NSColorToken.textTertiary : NSColorToken.textPrimary)
                    .strikethrough(a.taskDone ?? false)
                    .lineLimit(2)
                if let due = a.dueAt {
                    Text(dueFmt(due))
                        .font(NFont.mono(10))
                        .foregroundStyle(NSColorToken.textTertiary)
                }
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture { onPickAtom(a) }
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
    }

    private func dueFmt(_ d: Date) -> String {
        let df = DateFormatter(); df.dateFormat = "MMM d"
        return df.string(from: d).lowercased()
    }
}
