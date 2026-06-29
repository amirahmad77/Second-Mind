import SwiftUI
#if os(macOS)
import AppKit
#endif

// ─── GraphView — the living star chart ────────────────────────────────────────
//
// A constellation of the atom store rendered as a deep star field. Structure
// comes from MEANING (a kNN graph over the cached 768-d embeddings drives a live
// force simulation), and themes come from TAGS: atoms sharing a dominant tag form
// a soft, NAMED nebula. Semantic zoom keeps it legible — nebula names when zoomed
// out, individual atom labels when zoomed in.
//
// Serves all three jobs at once:
//   • explore  — nebulae name your themes; hover traces a star's constellation
//   • navigate — search, click-to-focus, an inspector with neighbour jump-links
//   • wow      — parallax dust, glow, twinkle, calm motion
//
// One Canvas, 60fps. macOS only (presented from MacSidebar).

struct GraphView: View {
    let store: AtomStore
    var onPickAtom: (AtomSnapshot) -> Void
    var onClose: () -> Void

    // ── Tuning ───────────────────────────────────────────────────────────────
    private static let maxNodes = 150
    private static let minRadius: CGFloat = 3.0
    private static let maxRadius: CGFloat = 13
    private static let knn = 4
    private static let simThreshold: Float = 0.58
    private static let warmSteps = 700          // hard cap; warm exits early on convergence
    private static let pauseEnergy: CGFloat = 3e-7
    private static let referenceExtent: CGFloat = 250
    private static let minZoom: CGFloat = 0.4
    private static let maxZoom: CGFloat = 6.0
    private static let minNebula = 3
    private static let maxNebulae = 8
    private static let dustCount = 140

    // ── Model ────────────────────────────────────────────────────────────────
    private struct NodeMeta {
        let id: UUID
        let snapshot: AtomSnapshot
        let type: AtomType
        let label: String
        let searchKey: String
        let tag: String?
        let pointRadius: CGFloat
        let twinkle: CGFloat   // phase
    }
    private struct Nebula {
        let name: String
        let color: Color
        let members: [Int]
    }
    private struct Mote { let x: CGFloat; let y: CGFloat; let r: CGFloat; let a: CGFloat; let phase: CGFloat }

    @State private var engine = ConstellationEngine()
    @State private var nodes: [NodeMeta] = []
    @State private var adjacency: [Int: Set<Int>] = [:]
    @State private var hubIndices: Set<Int> = []
    @State private var typeCounts: [AtomType: Int] = [:]
    @State private var nebulae: [Nebula] = []
    @State private var dust: [Mote] = []
    @State private var totalEdges = 0
    @State private var didBuild = false

    @State private var hoveredIndex: Int?
    @State private var selectedIndex: Int?
    @State private var visibleTypes: Set<AtomType> = Set(AtomType.allCases)
    @State private var searchText = ""

    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var viewSize: CGSize = .zero

    @State private var physicsHot = false
    @State private var dragMode: DragMode = .none
    @State private var panStart: CGSize = .zero
    @State private var lastPointer: CGPoint?
    @State private var lastMagnify: CGFloat = 1
    @State private var isInside = false
    @State private var appeared = false
    @State private var didInitialFit = false
    #if os(macOS)
    @State private var scrollMonitor: Any?
    #endif

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum DragMode: Equatable { case none, pan, node(Int) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            background
            field
            if didBuild, nodes.isEmpty { emptyState }
            header
            if didBuild, !nodes.isEmpty { controls }
            inspector
        }
        .frame(minWidth: 780, minHeight: 620)
        .onAppear(perform: buildIfNeeded)
        #if os(macOS)
        .onExitCommand {
            if selectedIndex != nil { selectedIndex = nil }
            else if !searchText.isEmpty { searchText = "" }
            else { onClose() }
        }
        #endif
    }

    // MARK: – Background

    private var background: some View {
        ZStack {
            NSColorToken.inkVoid
            RadialGradient(
                colors: [NSColorToken.inkRaised.opacity(0.40), NSColorToken.inkVoid.opacity(0)],
                center: .center, startRadius: 0, endRadius: 640
            )
            .blendMode(.plusLighter)
            .opacity(0.18)
        }
        .ignoresSafeArea()
    }

    // MARK: – Field

    @ViewBuilder
    private var field: some View {
        if didBuild, !nodes.isEmpty {
            GeometryReader { geo in
                // Full frame-rate while physics is hot (settling/dragging); throttle
                // when idle — 30fps for ambient twinkle, near-static for Reduce Motion
                // — so an open constellation doesn't pin the GPU at 60fps forever.
                TimelineView(.animation(minimumInterval: physicsHot ? nil : (reduceMotion ? 2.0 : 1.0 / 30.0))) { timeline in
                    Canvas { ctx, size in
                        if physicsHot {
                            engine.step()
                            if engine.energy < Self.pauseEnergy, dragMode == .none {
                                DispatchQueue.main.async { physicsHot = false }
                            }
                        }
                        draw(into: ctx, size: size,
                             time: timeline.date.timeIntervalSinceReferenceDate)
                    }
                }
                .contentShape(Rectangle())
                .gesture(dragGesture)
                .simultaneousGesture(singleTap)
                .simultaneousGesture(doubleTap)
                .simultaneousGesture(magnifyGesture)
                .onContinuousHover(coordinateSpace: .local) { phase in
                    switch phase {
                    case .active(let p):
                        isInside = true; lastPointer = p
                        if dragMode == .none { hoveredIndex = nearest(to: p) }
                    case .ended:
                        isInside = false; hoveredIndex = nil
                    }
                }
                .scaleEffect(appeared || reduceMotion ? 1 : 0.94)
                .opacity(appeared || reduceMotion ? 1 : 0)
                .onAppear {
                    viewSize = geo.size
                    installScrollMonitor()
                    initialFit()
                    withAnimation(reduceMotion ? nil : .nEaseOutQuint.delay(0.04)) { appeared = true }
                }
                .onDisappear { removeScrollMonitor() }
                .onChange(of: geo.size) { _, new in viewSize = new; initialFit() }
            }
        }
    }

    // MARK: – Drawing

    private func draw(into ctx: GraphicsContext, size: CGSize, time: TimeInterval) {
        let n = nodes.count
        guard n == engine.count, n > 0 else { return }
        let maxR = extent(for: size)
        let cx = size.width / 2 + offset.width
        let cy = size.height / 2 + offset.height
        let pts: [CGPoint] = (0..<n).map {
            CGPoint(x: cx + engine.pos[$0].x * maxR * scale,
                    y: cy + engine.pos[$0].y * maxR * scale)
        }
        let matches = matchedIndices()
        let searching = !searchText.isEmpty

        // 1 — parallax dust
        drawDust(into: ctx, size: size, time: time)

        // 2 — nebula haze
        let nebulaName = clamp(1 - (scale - 1.1) / 0.6)       // visible when zoomed out
        for neb in nebulae {
            guard neb.members.contains(where: { visibleTypes.contains(nodes[$0].type) }) else { continue }
            let member = neb.members.map { pts[$0] }
            var mx: CGFloat = 0, my: CGFloat = 0
            for p in member { mx += p.x; my += p.y }
            mx /= CGFloat(member.count); my /= CGFloat(member.count)
            var rad: CGFloat = 30
            for p in member { rad = max(rad, hypot(p.x - mx, p.y - my)) }
            rad += 26
            let center = CGPoint(x: mx, y: my)
            ctx.fill(
                circle(at: center, radius: rad),
                with: .radialGradient(
                    Gradient(colors: [neb.color.opacity(0.16), neb.color.opacity(0.04), .clear]),
                    center: center, startRadius: 0, endRadius: rad)
            )
        }

        // 3 — edges
        for e in engine.edges {
            let op = edgeOpacity(e, searching: searching, matches: matches)
            guard op > 0.002 else { continue }
            var path = Path()
            path.move(to: pts[e.a]); path.addLine(to: pts[e.b])
            let color = e.explicit ? NSColorToken.textSecondary : NSColorToken.Phos.cyan
            ctx.stroke(path, with: .color(color.opacity(op)), lineWidth: e.explicit ? 1.1 : 0.55)
        }

        // 4 — stars
        for i in 0..<n {
            let a = nodeAlpha(i, searching: searching, matches: matches)
            guard a > 0.02 else { continue }
            let p = pts[i]
            let isHover = hoveredIndex == i
            let isSel = selectedIndex == i
            let isMatch = searching && matches.contains(i)
            let color = nodes[i].type.phosphor
            let tw = reduceMotion ? 1.0 : 0.82 + 0.18 * sin(time * 1.4 + nodes[i].twinkle)
            let r = nodes[i].pointRadius * (isHover ? 1.28 : 1)

            ctx.fill(circle(at: p, radius: r * 2.2),
                     with: .color(color.opacity((isHover ? 0.34 : 0.15) * a * tw)))
            if isHover || isSel || isMatch {
                let ring = isMatch ? NSColorToken.textPrimary : color
                ctx.stroke(
                    Path(ellipseIn: CGRect(x: p.x - r - 5, y: p.y - r - 5, width: (r + 5) * 2, height: (r + 5) * 2)),
                    with: .color(ring.opacity((isHover ? 0.75 : 0.5) * a)), lineWidth: 1.5)
            }
            ctx.fill(circle(at: p, radius: r), with: .color(color.opacity(a * (0.9 + 0.1 * tw))))
        }

        // 5 — nebula names (semantic zoom: out)
        if nebulaName > 0.02 {
            for neb in nebulae {
                let visible = neb.members.filter { visibleTypes.contains(nodes[$0].type) }
                guard !visible.isEmpty else { continue }
                let member = visible.map { pts[$0] }
                var mx: CGFloat = 0, my: CGFloat = 0
                for p in member { mx += p.x; my += p.y }
                mx /= CGFloat(member.count); my /= CGFloat(member.count)
                var rad: CGFloat = 30
                for p in member { rad = max(rad, hypot(p.x - mx, p.y - my)) }
                let resolved = ctx.resolve(
                    Text(neb.name.uppercased())
                        .font(NFont.mono(11))
                        .foregroundColor(neb.color.opacity(0.9 * nebulaName))
                )
                ctx.draw(resolved, at: CGPoint(x: mx, y: my - rad - 30), anchor: .center)
            }
        }

        // 6 — atom labels (semantic zoom: in + hover/selected/search)
        drawLabels(into: ctx, points: pts, searching: searching, matches: matches)

        // 7 — hover tooltip
        if let h = hoveredIndex, dragMode == .none, visibleTypes.contains(nodes[h].type) {
            drawTooltip(into: ctx, at: pts[h], index: h, size: size)
        }
    }

    private func drawDust(into ctx: GraphicsContext, size: CGSize, time: TimeInterval) {
        // Parallax: dust drifts a fraction of the pan, for depth.
        let px = offset.width * 0.03, py = offset.height * 0.03
        for m in dust {
            let x = m.x * size.width + px
            let y = m.y * size.height + py
            let tw = reduceMotion ? 0.75 : 0.5 + 0.5 * sin(time * 0.6 + m.phase)
            ctx.fill(circle(at: CGPoint(x: x, y: y), radius: m.r),
                     with: .color(NSColorToken.textGhost.opacity(m.a * tw)))
        }
    }

    private func drawLabels(into ctx: GraphicsContext, points pts: [CGPoint],
                            searching: Bool, matches: Set<Int>) {
        let zoomedIn = clamp((scale - 1.4) / 0.7)   // atom labels emerge when zoomed in
        var candidates: [Int]
        if searching {
            candidates = Array(matches)
        } else if let h = focusIndex {
            candidates = [h] + (adjacency[h].map(Array.init) ?? [])
        } else {
            candidates = Array(hubIndices)
            if zoomedIn > 0.3 { candidates = Array(0..<nodes.count) }   // reveal more when close
        }
        candidates = candidates.filter { visibleTypes.contains(nodes[$0].type) }
        candidates.sort { a, b in
            let pa = (a == hoveredIndex || a == selectedIndex) ? 1 : 0
            let pb = (b == hoveredIndex || b == selectedIndex) ? 1 : 0
            if pa != pb { return pa > pb }
            return nodes[a].pointRadius > nodes[b].pointRadius
        }

        var accepted: [CGRect] = []
        var placed = 0
        let cap = zoomedIn > 0.3 ? 40 : 16
        for i in candidates {
            guard placed < cap else { break }
            let always = (i == hoveredIndex || i == selectedIndex || searching)
            let labelAlpha = always ? 1.0 : (hoveredIndex == nil ? max(Double(zoomedIn), hubIndices.contains(i) ? 0.55 : 0) : 1.0)
            guard labelAlpha > 0.05 else { continue }
            let p = pts[i]
            let isHover = hoveredIndex == i
            let display = String(nodes[i].label.prefix(30))
            let resolved = ctx.resolve(
                Text(display).font(NFont.monoSmall(9))
                    .foregroundColor((isHover ? NSColorToken.textPrimary : NSColorToken.textSecondary).opacity(labelAlpha))
            )
            let tsize = resolved.measure(in: CGSize(width: 220, height: 40))
            let center = CGPoint(x: p.x, y: p.y + nodes[i].pointRadius + 11)
            let rect = CGRect(x: center.x - tsize.width / 2 - 5, y: center.y - tsize.height / 2 - 2,
                              width: tsize.width + 10, height: tsize.height + 4)
            if accepted.contains(where: { $0.intersects(rect) }) { continue }
            accepted.append(rect); placed += 1
            ctx.fill(Path(roundedRect: rect, cornerRadius: rect.height / 2),
                     with: .color(NSColorToken.inkVoid.opacity(0.80 * labelAlpha)))
            ctx.draw(resolved, at: center, anchor: .center)
        }
    }

    private func drawTooltip(into ctx: GraphicsContext, at p: CGPoint, index i: Int, size: CGSize) {
        let meta = nodes[i]
        let title = String(meta.label.prefix(48))
        let sub = meta.tag.map { "\(meta.type.label) · #\($0)" } ?? meta.type.label
        let titleR = ctx.resolve(Text(title).font(NFont.mono(11)).foregroundColor(NSColorToken.textPrimary))
        let subR = ctx.resolve(Text(sub).font(NFont.monoSmall(9)).foregroundColor(meta.type.phosphor))
        let tW = titleR.measure(in: CGSize(width: 260, height: 30)).width
        let sW = subR.measure(in: CGSize(width: 260, height: 30)).width
        let w = min(280, max(tW, sW) + 20)
        let h: CGFloat = 42
        var x = p.x + 14, y = p.y - h - 10
        if x + w > size.width - 12 { x = p.x - w - 14 }
        if y < 60 { y = p.y + 16 }
        x = max(12, min(x, size.width - w - 12))
        let box = CGRect(x: x, y: y, width: w, height: h)
        ctx.fill(Path(roundedRect: box, cornerRadius: 9), with: .color(NSColorToken.inkRaised.opacity(0.96)))
        ctx.stroke(Path(roundedRect: box, cornerRadius: 9), with: .color(meta.type.phosphor.opacity(0.35)), lineWidth: 1)
        ctx.draw(titleR, at: CGPoint(x: x + 10, y: y + 14), anchor: .leading)
        ctx.draw(subR, at: CGPoint(x: x + 10, y: y + 30), anchor: .leading)
    }

    private func circle(at p: CGPoint, radius r: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
    }

    // MARK: – Visual weighting

    private func clamp(_ v: CGFloat) -> CGFloat { min(max(v, 0), 1) }

    /// What the constellation is currently tracing: a hovered star takes
    /// priority, otherwise the selected one — so clicking a star keeps its
    /// constellation lit while the inspector is open, not just on hover.
    private var focusIndex: Int? { hoveredIndex ?? selectedIndex }

    private func nodeAlpha(_ i: Int, searching: Bool, matches: Set<Int>) -> Double {
        if !visibleTypes.contains(nodes[i].type) { return 0.05 }
        if searching { return matches.contains(i) ? 1 : 0.08 }
        guard let h = focusIndex else { return 1 }
        if i == h { return 1 }
        return (adjacency[h]?.contains(i) ?? false) ? 1 : 0.32
    }

    private func edgeOpacity(_ e: ConstellationEngine.Edge, searching: Bool, matches: Set<Int>) -> Double {
        if !visibleTypes.contains(nodes[e.a].type) || !visibleTypes.contains(nodes[e.b].type) { return 0 }
        let weighted = Double(min(max((e.w - 0.5) / 0.5, 0), 1))
        let base = e.explicit ? 0.40 : (0.035 + 0.14 * weighted)
        if searching { return (matches.contains(e.a) && matches.contains(e.b)) ? base : base * 0.06 }
        guard let h = focusIndex else { return base }
        if e.a == h || e.b == h { return e.explicit ? 0.85 : 0.55 }
        return base * 0.28
    }

    private func matchedIndices() -> Set<Int> {
        let q = searchText.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return Set(nodes.indices.filter { nodes[$0].searchKey.contains(q) })
    }

    // MARK: – Header

    private var header: some View {
        HStack(alignment: .top, spacing: NSpace.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text("// constellation")
                    .font(NFont.mono(13)).foregroundStyle(NSColorToken.textSecondary)
                Text(subtitle)
                    .font(NFont.monoSmall(10)).foregroundStyle(NSColorToken.textGhost)
                    .monospacedDigit().lineLimit(1)
            }
            Spacer(minLength: NSpace.md)
            searchField
            zoomControls
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .medium))
                    .foregroundStyle(NSColorToken.textGhost).padding(NSpace.sm).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Close (esc)")
        }
        .padding(NSpace.md)
    }

    private var subtitle: String {
        if let s = selectedIndex, nodes.indices.contains(s) { return "› \(nodes[s].label)" }
        if !searchText.isEmpty { return "\(matchedIndices().count) matches" }
        let shown = nodes.filter { visibleTypes.contains($0.type) }.count
        let suffix = shown == nodes.count ? "" : " of \(nodes.count)"
        return "\(shown) atoms\(suffix) · \(totalEdges) connections · \(nebulae.count) themes"
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 10, weight: .medium))
                .foregroundStyle(NSColorToken.textGhost)
            TextField("search", text: $searchText)
                .textFieldStyle(.plain).font(NFont.mono(11))
                .foregroundStyle(NSColorToken.textPrimary).frame(width: 150)
                .onSubmit { focusBestMatch() }
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                        .foregroundStyle(NSColorToken.textGhost)
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, NSpace.sm).padding(.vertical, 5)
        .background(
            Capsule(style: .continuous).fill(NSColorToken.inkRaised.opacity(0.6))
                .overlay(Capsule().stroke(NSColorToken.textGhost.opacity(0.15), lineWidth: 1))
        )
        .onChange(of: searchText) { _, _ in frameMatches() }
    }

    private var zoomControls: some View {
        HStack(spacing: 2) {
            iconButton("minus") { zoom(by: 1 / 1.3, at: viewCenter) }
            iconButton("plus") { zoom(by: 1.3, at: viewCenter) }
            if scale != 1 || offset != .zero {
                Button(action: resetView) {
                    Text("reset").font(NFont.monoSmall(10)).foregroundStyle(NSColorToken.textGhost)
                        .padding(.horizontal, NSpace.sm).padding(.vertical, 5).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
    }

    private func iconButton(_ system: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system).font(.system(size: 10, weight: .semibold))
                .foregroundStyle(NSColorToken.textSecondary).frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 6).fill(NSColorToken.inkRaised.opacity(0.6)))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    // MARK: – Controls

    private var controls: some View {
        VStack(spacing: NSpace.sm) {
            Spacer()
            HStack(spacing: NSpace.xs) {
                ForEach(AtomType.allCases, id: \.self) { type in
                    if let count = typeCounts[type], count > 0 { typeChip(type, count: count) }
                }
            }
            Text("click focus · double-click open · drag star to move · scroll/pinch zoom · zoom in for labels")
                .font(NFont.monoSmall(9)).foregroundStyle(NSColorToken.textGhost.opacity(0.5))
                .padding(.bottom, NSpace.md)
        }
        .frame(maxWidth: .infinity)
        .allowsHitTesting(true)
    }

    private func typeChip(_ type: AtomType, count: Int) -> some View {
        let on = visibleTypes.contains(type)
        return Button { toggle(type) } label: {
            HStack(spacing: 5) {
                Circle().fill(type.phosphor).frame(width: 7, height: 7).opacity(on ? 1 : 0.35)
                Text(type.label).font(NFont.monoSmall(10))
                    .foregroundStyle(on ? NSColorToken.textSecondary : NSColorToken.textGhost)
                Text("\(count)").font(NFont.monoSmall(9)).foregroundStyle(NSColorToken.textGhost).monospacedDigit()
            }
            .padding(.horizontal, NSpace.sm).padding(.vertical, 5)
            .background(
                Capsule(style: .continuous).fill(NSColorToken.inkRaised.opacity(on ? 0.7 : 0.3))
                    .overlay(Capsule().stroke(type.phosphor.opacity(on ? 0.4 : 0), lineWidth: 1))
            )
            .contentShape(Capsule())
        }.buttonStyle(.plain)
    }

    private func toggle(_ type: AtomType) {
        if visibleTypes == [type] { visibleTypes = Set(AtomType.allCases) }
        else if visibleTypes.contains(type) {
            visibleTypes.remove(type)
            if visibleTypes.isEmpty { visibleTypes = Set(AtomType.allCases) }
        } else { visibleTypes.insert(type) }
        // Re-frame to what's now shown so a filtered subset fills the view.
        let vis = nodes.indices.filter { visibleTypes.contains(nodes[$0].type) }
        if !vis.isEmpty { frame(indices: vis, fill: 0.82, animated: true) }
    }

    // MARK: – Inspector

    @ViewBuilder
    private var inspector: some View {
        if let i = selectedIndex, nodes.indices.contains(i) {
            let meta = nodes[i]
            HStack {
                Spacer()
                VStack(alignment: .leading, spacing: NSpace.md) {
                    HStack {
                        HStack(spacing: 6) {
                            Circle().fill(meta.type.phosphor).frame(width: 8, height: 8)
                            Text("// \(meta.type.label)").font(NFont.monoSmall(10))
                                .foregroundStyle(meta.type.phosphor)
                        }
                        Spacer()
                        Button { selectedIndex = nil } label: {
                            Image(systemName: "xmark").font(.system(size: 10, weight: .medium))
                                .foregroundStyle(NSColorToken.textGhost)
                        }.buttonStyle(.plain)
                    }
                    Text(meta.label).font(NFont.detailBody(15)).foregroundStyle(NSColorToken.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !meta.snapshot.tags.isEmpty {
                        HStack(spacing: 5) {
                            ForEach(meta.snapshot.tags.prefix(4), id: \.value) { t in
                                Text("#\(t.value)").font(NFont.monoSmall(9))
                                    .foregroundStyle(NSColorToken.textTertiary)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Capsule().fill(NSColorToken.inkVoid.opacity(0.6)))
                            }
                        }
                    }
                    Divider().overlay(NSColorToken.textGhost.opacity(0.2))
                    let neighbours = (adjacency[i].map(Array.init) ?? [])
                        .filter { visibleTypes.contains(nodes[$0].type) }
                        .sorted { nodes[$0].pointRadius > nodes[$1].pointRadius }
                        .prefix(6)
                    if !neighbours.isEmpty {
                        Text("// related").font(NFont.monoSmall(9)).foregroundStyle(NSColorToken.textGhost)
                        ForEach(Array(neighbours), id: \.self) { j in
                            Button { selectedIndex = j; focus(on: j) } label: {
                                HStack(spacing: 6) {
                                    Circle().fill(nodes[j].type.phosphor).frame(width: 5, height: 5)
                                    Text(nodes[j].label).font(NFont.monoSmall(10))
                                        .foregroundStyle(NSColorToken.textSecondary).lineLimit(1)
                                    Spacer()
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                    Spacer()
                    Button { onPickAtom(meta.snapshot) } label: {
                        HStack {
                            Text("open").font(NFont.mono(11))
                            Image(systemName: "arrow.right").font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundStyle(NSColorToken.textPrimary)
                        .padding(.horizontal, NSpace.md).padding(.vertical, NSpace.sm)
                        .frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: 8).fill(meta.type.phosphor.opacity(0.22))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(meta.type.phosphor.opacity(0.5), lineWidth: 1)))
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                .padding(NSpace.lg)
                .frame(width: 280)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(NSColorToken.inkPaper.opacity(0.96))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(NSColorToken.textGhost.opacity(0.15), lineWidth: 1))
                )
                .padding(.trailing, NSpace.md)
                .padding(.top, 70)
                .padding(.bottom, 70)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            .animation(.nEaseOutQuint, value: selectedIndex)
        }
    }

    // MARK: – Empty state

    private var emptyState: some View {
        VStack(spacing: NSpace.sm) {
            Image(systemName: "sparkles").font(.system(size: 28, weight: .light))
                .foregroundStyle(NSColorToken.textGhost)
            Text("// no atoms yet").font(NFont.mono(12)).foregroundStyle(NSColorToken.textGhost)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: – Gestures

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .local)
            .onChanged { v in
                if dragMode == .none {
                    if let i = nearest(to: v.startLocation) {
                        dragMode = .node(i); engine.pinned[i] = true; physicsHot = true
                    } else { dragMode = .pan; panStart = offset }
                }
                switch dragMode {
                case .node(let i): engine.setPosition(i, contentPoint(v.location)); physicsHot = true
                case .pan: offset = clampedOffset(CGSize(width: panStart.width + v.translation.width,
                                                         height: panStart.height + v.translation.height))
                case .none: break
                }
            }
            .onEnded { _ in
                if case .node(let i) = dragMode { engine.pinned[i] = false; physicsHot = true }
                dragMode = .none
            }
    }

    private var singleTap: some Gesture {
        SpatialTapGesture(count: 1, coordinateSpace: .local).onEnded { e in
            if let i = nearest(to: e.location) { selectedIndex = i; focus(on: i) }
            else { selectedIndex = nil }
        }
    }

    private var doubleTap: some Gesture {
        SpatialTapGesture(count: 2, coordinateSpace: .local).onEnded { e in
            if let i = nearest(to: e.location) { onPickAtom(nodes[i].snapshot) }
        }
    }

    private var magnifyGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                let delta = value / lastMagnify; lastMagnify = value
                zoom(by: delta, at: lastPointer ?? viewCenter)
            }
            .onEnded { _ in lastMagnify = 1 }
    }

    // MARK: – Hit testing & transform

    private var viewCenter: CGPoint { CGPoint(x: viewSize.width / 2, y: viewSize.height / 2) }
    private func extent(for size: CGSize) -> CGFloat { max(40, min(size.width, size.height) / 2 - 80) }

    private func contentPoint(_ loc: CGPoint) -> CGPoint {
        let maxR = extent(for: viewSize)
        let denom = max(maxR * scale, 0.0001)
        return CGPoint(x: (loc.x - viewSize.width / 2 - offset.width) / denom,
                       y: (loc.y - viewSize.height / 2 - offset.height) / denom)
    }

    private func nearest(to loc: CGPoint) -> Int? {
        let n = nodes.count
        guard n == engine.count, n > 0 else { return nil }
        let maxR = extent(for: viewSize)
        let cx = viewSize.width / 2 + offset.width
        let cy = viewSize.height / 2 + offset.height
        var best: Int?; var bestD = CGFloat.greatestFiniteMagnitude
        for i in 0..<n {
            guard visibleTypes.contains(nodes[i].type) else { continue }
            let sx = cx + engine.pos[i].x * maxR * scale
            let sy = cy + engine.pos[i].y * maxR * scale
            let dx = sx - loc.x, dy = sy - loc.y
            let d = dx * dx + dy * dy
            let hit = nodes[i].pointRadius + 8
            if d <= hit * hit, d < bestD { bestD = d; best = i }
        }
        return best
    }

    private func clampZoom(_ s: CGFloat) -> CGFloat { min(max(s, Self.minZoom), Self.maxZoom) }

    /// Keep the cloud from being panned entirely out of view — always leaves a
    /// margin of stars on screen so you can never "lose" the constellation.
    private func clampedOffset(_ o: CGSize) -> CGSize {
        guard viewSize.width > 0 else { return o }
        let half = extent(for: viewSize) * scale   // cloud half-extent on screen
        let keep: CGFloat = 80
        let limitX = max(0, viewSize.width / 2 + half - keep)
        let limitY = max(0, viewSize.height / 2 + half - keep)
        return CGSize(width: min(max(o.width, -limitX), limitX),
                      height: min(max(o.height, -limitY), limitY))
    }

    private func zoom(by factor: CGFloat, at p: CGPoint) {
        let newScale = clampZoom(scale * factor)
        guard newScale != scale else { return }
        let ratio = newScale / scale
        let cx = viewSize.width / 2, cy = viewSize.height / 2
        scale = newScale
        offset = clampedOffset(CGSize(width: (p.x - cx) - ((p.x - cx) - offset.width) * ratio,
                                      height: (p.y - cy) - ((p.y - cy) - offset.height) * ratio))
    }

    private func resetView() {
        selectedIndex = nil
        frame(indices: nodes.indices.filter { visibleTypes.contains(nodes[$0].type) },
              fill: 0.82, animated: true)
    }

    private func focus(on i: Int) {
        guard engine.pos.indices.contains(i) else { return }
        let maxR = extent(for: viewSize)
        // Gentle: keep the current zoom if it's already comfortable; only ease in
        // when zoomed out. No jarring jump-to-2× on every click.
        let target = scale < 1.5 ? 1.8 : scale
        let p = engine.pos[i]
        // Bias left by ~half the inspector so the focused star isn't covered.
        let bias = min(150, viewSize.width * 0.18)
        withAnimation(.nEaseOutQuint) {
            scale = target
            offset = clampedOffset(CGSize(width: -p.x * maxR * target - bias,
                                          height: -p.y * maxR * target))
        }
    }

    private func focusBestMatch() {
        let m = matchedIndices()
        guard !m.isEmpty else { return }
        if let b = m.max(by: { (adjacency[$0]?.count ?? 0) < (adjacency[$1]?.count ?? 0) }) {
            selectedIndex = b; focus(on: b)
        }
    }

    /// Pan/zoom to fit a set of nodes within the viewport. Pure framing — never
    /// touches selection or physics, so it can run on every keystroke calmly.
    private func frame(indices: [Int], fill: CGFloat, animated: Bool) {
        guard viewSize.width > 0, !indices.isEmpty else { return }
        let maxR = extent(for: viewSize)
        var minX = CGFloat.greatestFiniteMagnitude, minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
        for i in indices where engine.pos.indices.contains(i) {
            let p = engine.pos[i]
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        guard minX <= maxX else { return }
        let bcx = (minX + maxX) / 2, bcy = (minY + maxY) / 2
        let hx = max((maxX - minX) / 2, 0.06), hy = max((maxY - minY) / 2, 0.06)
        let s = clampZoom(min(viewSize.width / 2 * fill / (maxR * hx),
                              viewSize.height / 2 * fill / (maxR * hy)))
        let newOffset = CGSize(width: -bcx * maxR * s, height: -bcy * maxR * s)
        if animated {
            withAnimation(.nEaseOutQuint) { scale = s; offset = newOffset }
        } else {
            scale = s; offset = newOffset
        }
    }

    /// One-time fit so any graph — sparse or dense — frames perfectly on open.
    private func initialFit() {
        guard !didInitialFit, didBuild, !nodes.isEmpty, viewSize.width > 0 else { return }
        didInitialFit = true
        frame(indices: nodes.indices.filter { visibleTypes.contains(nodes[$0].type) },
              fill: 0.82, animated: false)
    }

    /// Gently bring search matches into view as you type — no zoom lurch, no
    /// inspector pop. Enter (`focusBestMatch`) commits to the best single match.
    private func frameMatches() {
        let m = matchedIndices()
        guard !m.isEmpty else { return }
        frame(indices: Array(m), fill: 0.62, animated: true)
    }

    // MARK: – Scroll monitor

    private func installScrollMonitor() {
        #if os(macOS)
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard isInside, let p = lastPointer else { return event }
            let raw = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY
            guard raw != 0 else { return event }
            zoom(by: min(max(1 + raw * 0.0025, 0.85), 1.18), at: p)
            return nil
        }
        #endif
    }

    private func removeScrollMonitor() {
        #if os(macOS)
        if let m = scrollMonitor { NSEvent.removeMonitor(m); scrollMonitor = nil }
        #endif
    }

    // MARK: – Build

    private func buildIfNeeded() {
        guard !didBuild else { return }
        rebuildLayout()
        didBuild = true
    }

    private func rebuildLayout() {
        let live = store.ordered
        guard !live.isEmpty else { nodes = []; totalEdges = 0; return }

        let ranked = live
            .map { ($0, store.inboundCount(of: $0.id)) }
            .enumerated()
            .sorted { lhs, rhs in
                if lhs.element.1 != rhs.element.1 { return lhs.element.1 > rhs.element.1 }
                return lhs.offset < rhs.offset
            }
            .map { $0.element.0 }
        let capped = Array(ranked.prefix(Self.maxNodes))
        let ids = capped.map(\.id)
        let indexOf = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        let count = capped.count

        var edgeMap: [Int: (a: Int, b: Int, w: Float, explicit: Bool)] = [:]
        func key(_ i: Int, _ j: Int) -> Int { let lo = min(i, j), hi = max(i, j); return lo * (Self.maxNodes + 1) + hi }

        let vectors = store.embeddingVectors(forIDs: Set(ids))
        let vecList: [(idx: Int, vec: [Float])] = capped.enumerated().compactMap { idx, atom in
            vectors[atom.id].map { (idx, $0) }
        }
        for (i, vi) in vecList {
            var sims: [(Int, Float)] = []; sims.reserveCapacity(vecList.count)
            for (j, vj) in vecList where j != i {
                guard vi.count == vj.count else { continue }
                let s = RelatedFinder.cosineSimilarity(vi, vj)
                if s >= Self.simThreshold { sims.append((j, s)) }
            }
            sims.sort { $0.1 > $1.1 }
            for (j, s) in sims.prefix(Self.knn) {
                let k = key(i, j)
                if let ex = edgeMap[k] { if s > ex.w { edgeMap[k] = (ex.a, ex.b, s, ex.explicit) } }
                else { edgeMap[k] = (min(i, j), max(i, j), s, false) }
            }
        }
        for link in store.linkEdges {
            guard let a = indexOf[link.source], let b = indexOf[link.target], a != b else { continue }
            let k = key(a, b)
            if let ex = edgeMap[k] { edgeMap[k] = (ex.a, ex.b, max(ex.w, 0.92), true) }
            else { edgeMap[k] = (min(a, b), max(a, b), 0.92, true) }
        }
        let allEdges = Array(edgeMap.values)

        var degree = [Int](repeating: 0, count: count)
        for e in allEdges { degree[e.a] += 1; degree[e.b] += 1 }
        let maxDeg = degree.max() ?? 0
        let pointRadii = (0..<count).map { Self.radius(forDegree: degree[$0], maxDegree: maxDeg) }
        let normRadii = pointRadii.map { ($0 + 2) / Self.referenceExtent }

        var meta: [NodeMeta] = []; meta.reserveCapacity(count)
        var counts: [AtomType: Int] = [:]
        for (index, atom) in capped.enumerated() {
            let one = atom.oneLiner
            let tag = atom.tags.first?.value
            meta.append(NodeMeta(
                id: atom.id, snapshot: atom, type: atom.type,
                label: String(one.prefix(44)),
                searchKey: (one + " " + atom.type.label + " " + atom.tags.map(\.value).joined(separator: " ")).lowercased(),
                tag: tag,
                pointRadius: pointRadii[index],
                twinkle: CGFloat((sin(Double(index) * 12.9898) * 43758.5453).truncatingRemainder(dividingBy: 1)) * 6.28
            ))
            counts[atom.type, default: 0] += 1
        }

        var adj: [Int: Set<Int>] = [:]
        for e in allEdges { adj[e.a, default: []].insert(e.b); adj[e.b, default: []].insert(e.a) }
        let hubs = Set(degree.enumerated().sorted { $0.element > $1.element }
            .prefix(4).filter { $0.element > 0 }.map { $0.offset })

        // Nebulae by dominant tag.
        var byTag: [String: [Int]] = [:]
        for (idx, m) in meta.enumerated() { if let t = m.tag { byTag[t, default: []].append(idx) } }
        let nebs: [Nebula] = byTag
            .filter { $0.value.count >= Self.minNebula }
            .sorted { $0.value.count > $1.value.count }
            .prefix(Self.maxNebulae)
            .map { (name, members) in
                var typeTally: [AtomType: Int] = [:]
                for m in members { typeTally[meta[m].type, default: 0] += 1 }
                let domType = typeTally.max { $0.value < $1.value }?.key ?? .thought
                return Nebula(name: name, color: domType.phosphor, members: members)
            }

        // Deterministic dust.
        var motes: [Mote] = []; motes.reserveCapacity(Self.dustCount)
        for k in 0..<Self.dustCount {
            let fk = Double(k)
            func rnd(_ seed: Double) -> CGFloat {
                CGFloat((sin(fk * seed) * 43758.5453).truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1)
            }
            motes.append(Mote(x: rnd(12.9898), y: rnd(78.233), r: 0.4 + rnd(37.71) * 1.0,
                              a: 0.04 + rnd(93.13) * 0.12, phase: rnd(7.31) * 6.28))
        }

        let engEdges = allEdges.map {
            ConstellationEngine.Edge(a: $0.a, b: $0.b, w: CGFloat($0.w), explicit: $0.explicit)
        }
        engine.seed(count: count, radii: normRadii, edges: engEdges)
        engine.warm(maxSteps: Self.warmSteps, until: Self.pauseEnergy)

        nodes = meta; adjacency = adj; hubIndices = hubs; typeCounts = counts
        nebulae = nebs; dust = motes; totalEdges = allEdges.count
        // Opens already converged — physics stays cold until an interaction
        // (drag) re-heats it, so there is no live settle-jiggle on appear.
        physicsHot = false
        didInitialFit = false

        NousLogger.info("store", "graph built",
                        ["nodes": "\(count)", "edges": "\(allEdges.count)",
                         "embedded": "\(vecList.count)", "nebulae": "\(nebs.count)"])
    }

    private static func radius(forDegree degree: Int, maxDegree: Int) -> CGFloat {
        guard maxDegree > 0 else { return minRadius }
        let t = sqrt(CGFloat(degree) / CGFloat(maxDegree))
        return minRadius + (maxRadius - minRadius) * t
    }
}
