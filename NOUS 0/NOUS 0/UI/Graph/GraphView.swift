import SwiftUI

// ─── GraphView ──────────────────────────────────────────────────────────────
//
// Constellation / graph view of the atom store. Each atom is a phosphor dot
// coloured by its type, sized by how many other atoms link to it (inbound
// count). Edges (from `store.linkEdges`) are drawn as thin phosphor-tinted
// lines between node centres.
//
// Layout is DETERMINISTIC: no per-render random jitter. The most-linked atoms
// settle toward the centre; everyone else fans out onto concentric rings by
// recency. Identical store state → identical constellation every time.
//
// Phosphor Instrument aesthetic: inkVoid field, glowing nodes, mono labels,
// calm motion. macOS only (presented from MacSidebar).

struct GraphView: View {
    let store: AtomStore
    /// Host opens the picked atom (MacSidebar posts `.nousSelectAtom`).
    var onPickAtom: (AtomSnapshot) -> Void
    var onClose: () -> Void

    // ── Tuning constants ─────────────────────────────────────────────────────
    /// Hard cap on rendered nodes — keeps Canvas + hit-testing cheap on large
    /// stores. Newest atoms (and their links) are the most relevant.
    private static let maxNodes = 150
    private static let minRadius: CGFloat = 4
    private static let maxRadius: CGFloat = 16
    private static let labelMinRadius: CGFloat = 9   // nodes at/above this show a label
    private static let nodesPerRing = 14
    private static let ringGap: CGFloat = 90

    @State private var hoveredID: UUID?
    /// Captured once per appear so layout/cap is stable across hover redraws.
    @State private var layout = Layout.empty

    var body: some View {
        ZStack(alignment: .topLeading) {
            NSColorToken.inkVoid.ignoresSafeArea()

            if layout.nodes.isEmpty {
                emptyState
            } else {
                GeometryReader { geo in
                    constellation(in: geo.size)
                }
            }

            header
        }
        .frame(minWidth: 640, minHeight: 520)
        .onAppear { rebuildLayout() }
    }

    // MARK: – Header

    private var header: some View {
        HStack(spacing: NSpace.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text("// constellation")
                    .font(NFont.mono(13))
                    .foregroundStyle(NSColorToken.textSecondary)
                Text("\(layout.nodes.count) nodes · \(layout.edges.count) links")
                    .font(NFont.monoSmall(10))
                    .foregroundStyle(NSColorToken.textGhost)
                    .monospacedDigit()
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(NSColorToken.textGhost)
                    .padding(NSpace.sm)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(NSpace.md)
    }

    // MARK: – Empty state

    private var emptyState: some View {
        VStack(spacing: NSpace.sm) {
            Image(systemName: "circle.dotted")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(NSColorToken.textGhost)
            Text("// no connections yet")
                .font(NFont.mono(12))
                .foregroundStyle(NSColorToken.textGhost)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: – Constellation

    @ViewBuilder
    private func constellation(in size: CGSize) -> some View {
        let placed = positioned(in: size)
        ZStack {
            // Edges drawn beneath the nodes.
            Canvas { ctx, _ in
                for edge in layout.edges {
                    guard let a = placed[edge.source], let b = placed[edge.target] else { continue }
                    var path = Path()
                    path.move(to: a.point)
                    path.addLine(to: b.point)
                    // Tint the line toward the source node's phosphor, faint.
                    ctx.stroke(
                        path,
                        with: .color(a.node.type.phosphor.opacity(0.18)),
                        lineWidth: 0.75
                    )
                }
            }
            .allowsHitTesting(false)

            // Nodes.
            ForEach(layout.nodes) { node in
                if let p = placed[node.id] {
                    NodeDot(
                        color: node.type.phosphor,
                        label: node.label,
                        radius: node.radius,
                        center: p.point,
                        isHovered: hoveredID == node.id,
                        showLabel: node.radius >= Self.labelMinRadius || hoveredID == node.id
                    )
                    .onHover { hovering in
                        hoveredID = hovering ? node.id : (hoveredID == node.id ? nil : hoveredID)
                    }
                    .onTapGesture { onPickAtom(node.snapshot) }
                }
            }
        }
        .animation(.nEaseOutQuint, value: hoveredID)
    }

    // MARK: – Positioning (deterministic, scaled to bounds)

    private struct Placed { let point: CGPoint; let node: Node }

    /// Maps each node's normalized polar coordinate (ring index + angle) into the
    /// view bounds. Pure function of `layout` + `size` — no randomness.
    private func positioned(in size: CGSize) -> [UUID: Placed] {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        // Available radius leaves a margin so glow + labels stay on-screen.
        let maxR = max(40, min(size.width, size.height) / 2 - 60)
        let ringCount = max(1, layout.maxRing + 1)
        let ringStep = maxR / CGFloat(ringCount)

        var out: [UUID: Placed] = [:]
        out.reserveCapacity(layout.nodes.count)
        for node in layout.nodes {
            let r = ringStep * CGFloat(node.ring)
            let x = center.x + r * cos(node.angle)
            let y = center.y + r * sin(node.angle)
            out[node.id] = Placed(point: CGPoint(x: x, y: y), node: node)
        }
        return out
    }

    // MARK: – Layout build

    /// Snapshot of the graph topology. Polar coordinates are normalized
    /// (ring index + angle); `positioned(in:)` scales them to the live bounds.
    private struct Layout {
        let nodes: [Node]
        let edges: [(source: UUID, target: UUID)]
        let maxRing: Int
        static let empty = Layout(nodes: [], edges: [], maxRing: 0)
    }

    private struct Node: Identifiable {
        let id: UUID
        let snapshot: AtomSnapshot
        let type: AtomType
        let label: String
        let radius: CGFloat
        let ring: Int
        let angle: CGFloat
    }

    /// Builds the deterministic constellation from the store. Caps node count,
    /// sizes by inbound link count, places by (links desc → recency) onto rings.
    private func rebuildLayout() {
        let live = store.ordered  // newest-first, already excludes deleted
        guard !live.isEmpty else {
            layout = .empty
            NousLogger.info("store", "graph build — empty store")
            return
        }

        // Rank: most-linked first, ties broken by recency (ordered is newest-first,
        // so a stable sort preserves recency within equal link counts).
        let ranked = live
            .map { ($0, store.inboundCount(of: $0.id)) }
            .enumerated()
            .sorted { lhs, rhs in
                if lhs.element.1 != rhs.element.1 { return lhs.element.1 > rhs.element.1 }
                return lhs.offset < rhs.offset
            }
            .map { $0.element }

        let capped = Array(ranked.prefix(Self.maxNodes))
        if ranked.count > Self.maxNodes {
            NousLogger.info("store", "graph capped nodes",
                            ["total": "\(ranked.count)", "shown": "\(Self.maxNodes)"])
        }

        let maxLinks = capped.map(\.1).max() ?? 0
        let visibleIDs = Set(capped.map { $0.0.id })

        var nodes: [Node] = []
        nodes.reserveCapacity(capped.count)
        var maxRing = 0
        for (index, pair) in capped.enumerated() {
            let (atom, links) = pair
            let radius = Self.radius(forLinks: links, maxLinks: maxLinks)
            // Ring 0 holds the single most-connected node (center); subsequent
            // nodes fan out by rank. Angle is a deterministic golden-ish spread
            // within the ring so neighbours don't overlap.
            let ring = index == 0 ? 0 : ((index - 1) / Self.nodesPerRing) + 1
            maxRing = max(maxRing, ring)
            let posInRing = index == 0 ? 0 : (index - 1) % Self.nodesPerRing
            let angle = CGFloat(posInRing) * (2 * .pi / CGFloat(Self.nodesPerRing))
                + CGFloat(ring) * 0.4   // per-ring rotation so rings don't align radially
            nodes.append(Node(
                id: atom.id,
                snapshot: atom,
                type: atom.type,
                label: String(atom.oneLiner.prefix(40)),
                radius: radius,
                ring: ring,
                angle: angle
            ))
        }

        // Only edges where both endpoints are visible (post-cap).
        let edges = store.linkEdges.filter {
            visibleIDs.contains($0.source) && visibleIDs.contains($0.target)
        }

        layout = Layout(nodes: nodes, edges: edges, maxRing: maxRing)
        NousLogger.info("store", "graph built",
                        ["nodes": "\(nodes.count)", "edges": "\(edges.count)"])
    }

    /// Node radius scales with inbound link count (sqrt for gentle growth).
    private static func radius(forLinks links: Int, maxLinks: Int) -> CGFloat {
        guard maxLinks > 0 else { return minRadius }
        let t = sqrt(CGFloat(links) / CGFloat(maxLinks))
        return minRadius + (maxRadius - minRadius) * t
    }
}

// ─── NodeDot ──────────────────────────────────────────────────────────────────
//
// A single phosphor node. Full chroma + bloom when hovered, dimmed otherwise so
// the eye gets peaks and rests. Optional mono label for larger / hovered nodes.

private struct NodeDot: View {
    let color: Color
    let label: String
    let radius: CGFloat
    let center: CGPoint
    let isHovered: Bool
    let showLabel: Bool

    var body: some View {
        VStack(spacing: 3) {
            Circle()
                .fill(color)
                .frame(width: radius * 2, height: radius * 2)
                .shadow(
                    color: color.opacity(isHovered ? 0.9 : 0.5),
                    radius: isHovered ? NSColorToken.Phos.activeGlow + 4 : NSColorToken.Phos.activeGlow / 2
                )
                .opacity(isHovered ? 1.0 : 0.85)
                .scaleEffect(isHovered ? 1.15 : 1.0)

            if showLabel && !label.isEmpty {
                Text(label)
                    .font(NFont.monoSmall(9))
                    .foregroundStyle(isHovered ? NSColorToken.textSecondary : NSColorToken.textGhost)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 120)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .position(center)
        .contentShape(Rectangle())
    }
}
