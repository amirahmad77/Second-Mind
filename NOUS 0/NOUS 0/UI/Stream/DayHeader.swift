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
        .padding(.top, NSpace.x4)
        .padding(.bottom, NSpace.lg)
    }

    private var dayName: String {
        let df = DateFormatter(); df.dateFormat = "EEEE"
        return df.string(from: date).lowercased()
    }
    private var meta: String {
        var s = "· \(count) atom\(count == 1 ? "" : "s")"
        if mtgCount > 0 { s += " · \(mtgCount) mtg" }
        return s
    }
}
