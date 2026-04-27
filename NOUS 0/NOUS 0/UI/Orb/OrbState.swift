import SwiftUI

enum OrbMode: Equatable {
    case idle
    case textActive
    case voice(amp: Double)
    case voiceCancelZone
    case search
    case synthesis
    case refining   // ambient indicator (any atom refining in background)
}

struct OrbVisual {
    let haloColor: Color
    let haloAlpha: Double
    let haloBlur: CGFloat
    let haloRadius: CGFloat
    let bodySize: CGFloat
    let amp: Double
    let phos: Color
    let breathe: Bool
    let label: String?

    static func from(_ mode: OrbMode) -> OrbVisual {
        switch mode {
        case .idle:
            return .init(haloColor: NSColorToken.Phos.cyan, haloAlpha: 0.22, haloBlur: 32,
                         haloRadius: 88, bodySize: 64, amp: 0, phos: NSColorToken.Phos.cyan,
                         breathe: true, label: nil)
        case .textActive:
            return .init(haloColor: NSColorToken.Phos.cyan, haloAlpha: 0.32, haloBlur: 40,
                         haloRadius: 96, bodySize: 64, amp: 0.1, phos: NSColorToken.Phos.cyan,
                         breathe: false, label: nil)
        case .voice(let amp):
            let a = max(0, min(1, amp))
            let c: Color = a > 0.78 ? NSColorToken.Phos.orange : NSColorToken.Phos.amber
            return .init(haloColor: c, haloAlpha: 0.25 + 0.25 * a, haloBlur: 48 + 16 * CGFloat(a),
                         haloRadius: 96 + 48 * CGFloat(a), bodySize: 64 + 24 * CGFloat(a),
                         amp: a, phos: c, breathe: false, label: nil)
        case .voiceCancelZone:
            return .init(haloColor: NSColorToken.textGhost, haloAlpha: 0.20, haloBlur: 24,
                         haloRadius: 72, bodySize: 64, amp: 0, phos: NSColorToken.textGhost,
                         breathe: false, label: "release to discard")
        case .search:
            return .init(haloColor: NSColorToken.Phos.blue, haloAlpha: 0.26, haloBlur: 56,
                         haloRadius: 120, bodySize: 72, amp: 0.05, phos: NSColorToken.Phos.blue,
                         breathe: false, label: nil)
        case .synthesis:
            return .init(haloColor: NSColorToken.Phos.violet, haloAlpha: 0.28, haloBlur: 56,
                         haloRadius: 116, bodySize: 70, amp: 0.05, phos: NSColorToken.Phos.violet,
                         breathe: false, label: nil)
        case .refining:
            return .init(haloColor: NSColorToken.Phos.amber, haloAlpha: 0.12, haloBlur: 40,
                         haloRadius: 96, bodySize: 64, amp: 0, phos: NSColorToken.Phos.amber,
                         breathe: true, label: nil)
        }
    }
}
