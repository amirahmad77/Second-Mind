import SwiftUI

struct AtomDot: View {
    let type: AtomType
    var size: CGFloat = 8
    var body: some View {
        Circle()
            .fill(type.phosphor)
            .frame(width: size, height: size)
            .shadow(color: type.phosphor.opacity(0.55), radius: 6)
            .shadow(color: type.phosphor.opacity(0.30), radius: 14)
    }
}
