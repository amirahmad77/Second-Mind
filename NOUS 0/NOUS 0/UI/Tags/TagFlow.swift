import SwiftUI

/// Wrapping horizontal layout for tag chips. Pure SwiftUI Layout protocol — no
/// hidden hacks, no GeometryReader. Chips wrap to the next line when they would
/// exceed the container width.
struct TagFlow: Layout {
    var hSpacing: CGFloat = NSpace.sm
    var vSpacing: CGFloat = NSpace.xs

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var (rowW, rowH, totalH, maxRowW): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)

        for sub in subviews {
            let s = sub.sizeThatFits(.unspecified)
            if rowW + (rowW > 0 ? hSpacing : 0) + s.width > maxW, rowW > 0 {
                totalH += rowH + vSpacing
                maxRowW = max(maxRowW, rowW)
                rowW = s.width
                rowH = s.height
            } else {
                if rowW > 0 { rowW += hSpacing }
                rowW += s.width
                rowH = max(rowH, s.height)
            }
        }
        totalH += rowH
        maxRowW = max(maxRowW, rowW)
        let finalW = proposal.width ?? maxRowW
        return CGSize(width: finalW, height: totalH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        var x = bounds.minX
        var y = bounds.minY
        var rowH: CGFloat = 0
        let maxX = bounds.maxX

        for sub in subviews {
            let s = sub.sizeThatFits(.unspecified)
            if x + s.width > maxX, x > bounds.minX {
                x = bounds.minX
                y += rowH + vSpacing
                rowH = 0
            }
            sub.place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                      proposal: ProposedViewSize(width: s.width, height: s.height))
            x += s.width + hSpacing
            rowH = max(rowH, s.height)
        }
    }
}
