import SwiftUI

/// Cross-fade w/ subtle scanline glitch when refined text arrives or when toggling raw↔refined.
struct CrossFadeText: View {
    let raw: String
    let refined: String?
    let showRaw: Bool
    let isRefining: Bool

    @State private var visible: String = ""
    @State private var blurRad: CGFloat = 0
    @State private var scanlineY: CGFloat = -1

    var body: some View {
        let target = showRaw ? raw : (refined ?? raw)
        ZStack(alignment: .topLeading) {
            Text(visible.isEmpty ? target : visible)
                .blur(radius: blurRad)
                .animation(.nEaseOutQuint, value: blurRad)

            if isRefining {
                GeometryReader { geo in
                    Rectangle()
                        .fill(NSColorToken.Phos.cyan.opacity(0.25))
                        .frame(height: 1)
                        .blur(radius: 1.5)
                        .offset(y: geo.size.height * scanlineY)
                        .animation(.linear(duration: 1.2).repeatForever(autoreverses: false), value: scanlineY)
                        .onAppear { scanlineY = 1.2 }
                        .onDisappear { scanlineY = -1 }
                }
                .allowsHitTesting(false)
            }
        }
        .onAppear { visible = target }
        .onChange(of: target) { _, new in crossfade(to: new) }
    }

    private func crossfade(to new: String) {
        withAnimation(.nEaseOutQuint) { blurRad = 2 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            visible = new
            withAnimation(.nEaseOutQuint) { blurRad = 0 }
        }
    }
}
