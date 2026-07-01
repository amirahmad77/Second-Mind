import SwiftUI

struct DayHeader: View {
    let date: Date
    let count: Int
    let mtgCount: Int

    var body: some View {
        HStack(alignment: .lastTextBaseline) {
            Text(dayName)
                .font(NFont.dayHeader(28))
                .foregroundStyle(NSColorToken.textPrimary)
            Spacer(minLength: NSpace.lg)
            Text(meta)
                .font(NFont.mono(11))
                .foregroundStyle(NSColorToken.textSecondary)
                .monospacedDigit()
        }
        .padding(.top, NSpace.xl)
        .padding(.bottom, NSpace.lg)
    }

    private var dayName: String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "today" }
        if cal.isDateInYesterday(date) { return "yesterday" }
        let df = DateFormatter()
        df.dateFormat = "EEEE"
        let weekday = df.string(from: date).lowercased()
        let daysAgo = cal.dateComponents([.day],
            from: cal.startOfDay(for: date),
            to: cal.startOfDay(for: .now)).day ?? 0
        guard daysAgo > 6 else { return weekday }
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "MMM d"
        return "\(weekday)  ·  \(dateFmt.string(from: date).lowercased())"
    }
    private var meta: String {
        var s = "· \(count) atom\(count == 1 ? "" : "s")"
        if mtgCount > 0 { s += " · \(mtgCount) mtg" }
        return s
    }
}
