import Foundation
import CoreGraphics

// ─── ConstellationEngine ──────────────────────────────────────────────────────
//
// A small force-directed physics engine for the constellation graph. Positions
// live in a normalized space (~[-1,1]); the view maps them through its own
// pan/zoom transform. Integration is velocity + damping (a relaxed spring system)
// so the graph MOVES — it settles smoothly on open, reacts when you grab a node,
// and re-settles when you let go.
//
// Plain reference type (not @Observable): the view's TimelineView is the clock
// and reads positions every frame, so no per-mutation publishing is needed.
// MainActor-bound because the view drives it from the main run loop.

@MainActor
final class ConstellationEngine {
    struct Edge {
        let a: Int
        let b: Int
        let w: CGFloat        // similarity weight 0…1 (explicit links pinned high)
        let explicit: Bool
    }

    private(set) var pos: [CGPoint] = []
    private(set) var vel: [CGPoint] = []
    var pinned: [Bool] = []
    private(set) var radii: [CGFloat] = []   // normalized collision radii
    private(set) var edges: [Edge] = []
    /// Mean kinetic energy of the last step — the view uses this to pause ticking
    /// once the graph has settled (saves CPU/battery).
    private(set) var energy: CGFloat = 1

    // Tuned for normalized space. These mirror the constants that converged well
    // statically; damping replaces the old per-iteration cooling.
    private let repulsion: CGFloat = 0.026
    private let springK: CGFloat = 0.060
    private let gravity: CGFloat = 0.015
    private let damping: CGFloat = 0.84
    private let gain: CGFloat = 0.90
    private let maxSpeed: CGFloat = 0.075

    var count: Int { pos.count }

    func seed(count n: Int, radii r: [CGFloat], edges e: [Edge]) {
        let golden = CGFloat.pi * (3 - sqrt(5))
        pos = (0..<n).map { i in
            let rad = sqrt(CGFloat(i) + 0.5) / sqrt(CGFloat(max(n, 1)))
            let a = CGFloat(i) * golden
            return CGPoint(x: rad * cos(a), y: rad * sin(a))
        }
        vel = Array(repeating: .zero, count: n)
        pinned = Array(repeating: false, count: n)
        radii = r
        edges = e
        energy = 1
    }

    /// Pre-settle synchronously so the graph opens already in shape, then the
    /// view animates the final polish live.
    func warm(_ steps: Int) {
        for _ in 0..<steps { step() }
        recenter()
    }

    /// Directly place a node (used while dragging). Caller pins/unpins.
    func setPosition(_ i: Int, _ p: CGPoint) {
        guard pos.indices.contains(i) else { return }
        pos[i] = p
        vel[i] = .zero
    }

    /// One integration step.
    func step() {
        let n = pos.count
        guard n > 1 else { return }
        var disp = [CGPoint](repeating: .zero, count: n)

        // All-pairs repulsion (n ≤ 150).
        for i in 0..<n {
            let pi = pos[i]
            for j in (i + 1)..<n {
                var dx = pi.x - pos[j].x
                var dy = pi.y - pos[j].y
                var d2 = dx * dx + dy * dy
                if d2 < 1e-4 { d2 = 1e-4; dx = 0.001; dy = 0.001 }
                let d = sqrt(d2)
                let f = repulsion / d2
                let ux = dx / d, uy = dy / d
                disp[i].x += ux * f; disp[i].y += uy * f
                disp[j].x -= ux * f; disp[j].y -= uy * f
            }
        }

        // Weighted spring attraction.
        for e in edges {
            let rest = 0.06 + (1 - e.w) * 0.18
            let dx = pos[e.b].x - pos[e.a].x
            let dy = pos[e.b].y - pos[e.a].y
            let d = max(sqrt(dx * dx + dy * dy), 1e-4)
            let f = (d - rest) * springK * (0.5 + e.w)
            let ux = dx / d, uy = dy / d
            disp[e.a].x += ux * f; disp[e.a].y += uy * f
            disp[e.b].x -= ux * f; disp[e.b].y -= uy * f
        }

        // Centering gravity + velocity integration with damping.
        var ke: CGFloat = 0
        for i in 0..<n {
            disp[i].x -= pos[i].x * gravity
            disp[i].y -= pos[i].y * gravity
            if pinned[i] { vel[i] = .zero; continue }
            var vx = vel[i].x * damping + disp[i].x * gain
            var vy = vel[i].y * damping + disp[i].y * gain
            let sp = sqrt(vx * vx + vy * vy)
            if sp > maxSpeed { vx *= maxSpeed / sp; vy *= maxSpeed / sp }
            vel[i] = CGPoint(x: vx, y: vy)
            pos[i].x += vx; pos[i].y += vy
            ke += vx * vx + vy * vy
        }

        // One collision pass so dots in a cluster don't overlap.
        for i in 0..<n {
            for j in (i + 1)..<n {
                var dx = pos[i].x - pos[j].x
                var dy = pos[i].y - pos[j].y
                let d = sqrt(dx * dx + dy * dy)
                let need = radii[i] + radii[j]
                if d < need {
                    let safe = max(d, 1e-4)
                    if d < 1e-4 { dx = 0.001; dy = 0.001 }
                    let push = (need - safe) / 2
                    let ux = dx / safe, uy = dy / safe
                    if !pinned[i] { pos[i].x += ux * push; pos[i].y += uy * push }
                    if !pinned[j] { pos[j].x -= ux * push; pos[j].y -= uy * push }
                }
            }
        }

        energy = ke / CGFloat(n)
    }

    /// Recenter the cloud on its centroid (keeps it from drifting). Not scaled —
    /// the view owns scaling — so dragging a node doesn't get fought by it.
    func recenter() {
        let n = pos.count
        guard n > 0 else { return }
        var cx: CGFloat = 0, cy: CGFloat = 0
        for p in pos { cx += p.x; cy += p.y }
        cx /= CGFloat(n); cy /= CGFloat(n)
        for i in 0..<n { pos[i].x -= cx; pos[i].y -= cy }
    }
}
