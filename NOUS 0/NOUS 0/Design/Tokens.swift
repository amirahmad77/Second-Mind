import SwiftUI

enum NSColorToken {
    static let inkVoid        = Color.oklch(0.10, 0.012, 240)
    static let inkPaper       = Color.oklch(0.14, 0.010, 240)
    static let inkRaised      = Color.oklch(0.18, 0.008, 240)
    static let inkMembrane    = Color.oklch(0.22, 0.006, 240, opacity: 0.55)
    static let inkScrim       = Color.oklch(0.06, 0.012, 240, opacity: 0.50)

    static let textPrimary    = Color.oklch(0.95, 0.005, 240)
    static let textSecondary  = Color.oklch(0.72, 0.008, 240)
    static let textTertiary   = Color.oklch(0.52, 0.010, 240)
    static let textGhost      = Color.oklch(0.36, 0.012, 240)

    enum Phos {
        static let cyan   = Color.oklch(0.82, 0.16, 200)
        static let blue   = Color.oklch(0.74, 0.20, 250)
        static let green  = Color.oklch(0.86, 0.20, 145)
        static let amber  = Color.oklch(0.84, 0.18,  75)
        static let orange = Color.oklch(0.74, 0.20,  45)
        static let violet = Color.oklch(0.70, 0.18, 295)
    }
}

enum NSpace {
    static let xs: CGFloat = 4, sm: CGFloat = 8, md: CGFloat = 12
    static let lg: CGFloat = 16, xl: CGFloat = 24, xxl: CGFloat = 32
    static let xxxl: CGFloat = 48, x4: CGFloat = 64, x5: CGFloat = 96
}

/// Font stack: primary picks if bundled, else graceful fallbacks. All ship-safe.
enum NFont {
    // Display (day headers) — serif italic w/ character. Fallback: system serif italic.
    static func dayHeader(_ size: CGFloat = 28) -> Font {
        Font.system(size: size, weight: .light, design: .serif).italic()
    }
    // Body — humanist. Fallback: system rounded-less default.
    static func body(_ size: CGFloat = 16) -> Font {
        Font.system(size: size, weight: .regular, design: .default)
    }
    static func detailBody(_ size: CGFloat = 17) -> Font {
        Font.system(size: size, weight: .regular, design: .default)
    }
    // Mono — instrument register. System mono is adequate until Berkeley/Departure bundled.
    static func mono(_ size: CGFloat = 11) -> Font {
        Font.system(size: size, weight: .regular, design: .monospaced)
    }
    static func monoSmall(_ size: CGFloat = 10) -> Font {
        Font.system(size: size, weight: .medium, design: .monospaced)
    }
}

extension Animation {
    static let nEaseOutQuint  = Animation.timingCurve(0.23, 1.0, 0.32, 1.0, duration: 0.22)
    static let nEaseInOutQuint = Animation.timingCurve(0.77, 0.0, 0.175, 1.0, duration: 0.32)
    static let nDrawer        = Animation.timingCurve(0.32, 0.72, 0.0, 1.0, duration: 0.42)
    static let nBreath        = Animation.timingCurve(0.45, 0.0, 0.55, 1.0, duration: 4.2)
    static let nPress         = Animation.timingCurve(0.4, 0.0, 0.2, 1.0, duration: 0.14)
    static func nLiveSpring(response: Double = 0.42, damp: Double = 0.78) -> Animation {
        .interactiveSpring(response: response, dampingFraction: damp, blendDuration: 0.1)
    }
}
