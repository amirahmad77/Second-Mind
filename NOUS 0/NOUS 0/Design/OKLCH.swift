import SwiftUI

/// Convert OKLCH → sRGB Color. Minimal inline impl, no deps.
extension Color {
    /// L: 0..1, C: chroma (~0..0.37), H: hue degrees 0..360.
    static func oklch(_ L: Double, _ C: Double, _ Hdeg: Double, opacity: Double = 1) -> Color {
        let H = Hdeg * .pi / 180
        let a = C * cos(H)
        let b = C * sin(H)
        // OKLab → linear sRGB (Björn Ottosson)
        let l_ = L + 0.3963377774 * a + 0.2158037573 * b
        let m_ = L - 0.1055613458 * a - 0.0638541728 * b
        let s_ = L - 0.0894841775 * a - 1.2914855480 * b
        let l = l_ * l_ * l_
        let m = m_ * m_ * m_
        let s = s_ * s_ * s_
        var r =  4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
        var g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
        var bl = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
        // Clamp
        r = max(0, min(1, r)); g = max(0, min(1, g)); bl = max(0, min(1, bl))
        // Linear → gamma sRGB
        func enc(_ x: Double) -> Double { x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1/2.4) - 0.055 }
        return Color(.sRGB, red: enc(r), green: enc(g), blue: enc(bl), opacity: opacity)
    }
}
