import SwiftUI

// MARK: - Formatting

enum Fmt {
    /// "1.24 kW" when |w| >= 1000, else "283 W".
    static func watts(_ w: Int) -> String {
        let a = abs(w)
        if a >= 1000 {
            return String(format: "%.2f kW", Double(a) / 1000.0)
        }
        return "\(a) W"
    }
}

// MARK: - Palette

enum Palette {
    static let pv = Color(red: 0.66, green: 0.85, blue: 0.23)     // yellow-green
    static let mi = Color(red: 0.30, green: 0.82, blue: 0.48)     // green
    static let gridImport = Color(red: 1.00, green: 0.45, blue: 0.30)
    static let gridExport = Color(red: 0.22, green: 0.80, blue: 0.75)
    static let batteryCharge = Color(red: 0.34, green: 0.82, blue: 0.46)
    static let batteryDischarge = Color(red: 1.00, green: 0.62, blue: 0.20)
    static let house = Color(red: 0.34, green: 0.62, blue: 1.00)
    static let ev = Color(red: 0.66, green: 0.50, blue: 0.98)
    static let idle = Color.gray
}

// MARK: - Flow direction

enum FlowDir {
    case none, toInverter, fromInverter
}

// MARK: - Node model

private struct Node {
    let symbol: String
    let name: String
    let value: String       // primary value (watts, or SOC% for battery)
    let secondary: String?  // secondary line (watts for battery, subtitle otherwise)
    let color: Color
    let dir: FlowDir
    let active: Bool
    let socPrimary: Bool    // battery renders SOC as the bold primary
    var tertiary: String? = nil  // battery time-left line (Flow D1)
}

// MARK: - Glow sprite

/// Pre-rendered glowing-dot sprite (solid dot + baked gaussian glow), cached
/// per color/size/scale. Replaces the per-dot ctx.drawLayer + .shadow filter:
/// each of those rented a RenderBox offscreen surface per dot per frame at
/// 30 fps, arming ~1.8k dispatch eviction timers/s. Stamping a cached image is
/// one textured quad -- no offscreen pass, no filter, no timer.
@MainActor
private enum GlowSprite {
    private struct Key: Hashable {
        let color: Color; let r: CGFloat; let blur: CGFloat; let scale: CGFloat
    }
    private static var cache: [Key: NSImage] = [:]

    /// Square sprite, `2r + 4*blur` points on a side.
    static func image(color: Color, r: CGFloat, blur: CGFloat, displayScale: CGFloat) -> NSImage {
        let key = Key(color: color, r: r, blur: blur, scale: displayScale)
        if let hit = cache[key] { return hit }
        // Same composite as the old filter: blurred copy behind a solid dot.
        let renderer = ImageRenderer(content:
            Circle().fill(color)
                .frame(width: r * 2, height: r * 2)
                .shadow(color: color.opacity(0.9), radius: blur)
                .padding(blur * 2)          // room for the gaussian tail
        )
        renderer.scale = displayScale
        let img = renderer.nsImage ?? NSImage()
        cache[key] = img
        return img
    }
}

// MARK: - FlowView

struct FlowView: View {
    @ObservedObject var poller: DataPoller
    @ObservedObject var settings: Settings
    /// Which display mode to render.
    var displayMode: DisplayMode = .flowChart
    /// Uniform size multiplier. All point sizes are parameterized (not
    /// rasterized via scaleEffect) so text stays crisp at every preset.
    var scale: CGFloat = 1.0

    // ponytail: single Bool flipped once in onAppear; Core Animation interpolates
    // the repeatForever breathe on the render server. Costs no per-frame CPU,
    // unlike re-evaluating the view body from a TimelineView.
    @State private var breathing = false

    /// Backing-store scale the glow sprites are rasterized at (2 on Retina).
    @Environment(\.displayScale) private var displayScale

    // Base design: 440x400 flow, +330 wide chart pane; Dashboard is 620 wide.
    static let flowWidth: CGFloat = 440
    static let chartWidth: CGFloat = 330
    static let dashboardWidth: CGFloat = 680
    static let baseHeight: CGFloat = 400

    /// `--etashots` only: ImageRenderer can't draw the dot NSView and paints a
    /// placeholder over the layout, so offscreen renders skip it.
    static var offscreen = false

    private var nodeR: CGFloat { 25 * scale }   // node circle radius
    private var invR: CGFloat { 30 * scale }    // inverter circle radius

    /// Scale a base point value.
    private func sc(_ v: CGFloat) -> CGFloat { v * scale }

    /// Total content size for the current configuration.
    static func contentSize(displayMode: DisplayMode, scale: CGFloat) -> CGSize {
        let base: CGFloat
        switch displayMode {
        case .flow: base = flowWidth
        case .flowChart: base = flowWidth + chartWidth
        case .dashboard: base = dashboardWidth
        }
        return CGSize(width: base * scale, height: baseHeight * scale)
    }

    var body: some View {
        ZStack {
            // Dark gradient overlay so content pops on any wallpaper.
            LinearGradient(
                colors: [Color.black.opacity(0.20), Color.black.opacity(0.45)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            switch displayMode {
            case .flow:
                flowColumn.frame(width: sc(Self.flowWidth))
            case .flowChart:
                HStack(spacing: 0) {
                    flowColumn
                        .frame(width: sc(Self.flowWidth))
                    Rectangle()
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 1)
                    ChartPane(poller: poller, scale: scale)
                        .frame(width: sc(Self.chartWidth) - 1)
                }
            case .dashboard:
                dashboardView
            }
        }
        .frame(width: Self.contentSize(displayMode: displayMode, scale: scale).width,
               height: Self.contentSize(displayMode: displayMode, scale: scale).height)
        .animation(.spring(duration: 0.6), value: poller.data)
        .animation(.easeInOut(duration: 0.4), value: poller.connected)
    }

    /// The original flow graph + capsules (unchanged 440-wide layout).
    private var flowColumn: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, sc(18))
                .padding(.top, sc(14))
                .padding(.bottom, sc(2))
            flowArea
                .padding(.horizontal, sc(14))
            statsStrip
                .padding(.horizontal, sc(16))
                .padding(.bottom, sc(14))
                .padding(.top, sc(2))
        }
    }

    // MARK: - Dashboard mode v2 (magnitude-driven tiers + semantic tint)

    private enum Tier { case hero, active, idle }

    /// Semantic (direction) colors layered over each node's identity hue.
    private enum Semantic {
        static let feed = Color(hue: 0.37, saturation: 0.55, brightness: 0.72)   // ~133° spring green
        static let draw = Color(hue: 0.035, saturation: 0.78, brightness: 0.98)  // ~13° coral
        static let exportTeal = Palette.gridExport
        static let idle = Color.gray
    }

    private struct DashNode {
        let kind: NodeKind
        let name: String
        let icon: String
        let identity: Color   // badge hue
        let semantic: Color   // stroke / wash / value / connector
        let magnitude: Double // |W|
        let big: String
        let unit: String
        let secondary: String
        let feeding: Bool     // dot travel: true = node -> inverter
    }

    private func bigWatts(_ w: Int) -> (String, String) {
        let a = abs(w)
        if a >= 1000 { return (String(format: "%.2f", Double(a) / 1000.0), "kW") }
        return ("\(a)", "W")
    }

    private func magnitudeOf(_ k: NodeKind, _ d: InverterData) -> Double {
        switch k {
        case .pv: return Double(d.pvTotal)
        case .mi: return Double(abs(d.miPower))
        case .grid: return Double(abs(d.gridPower))
        case .battery: return Double(abs(d.batteryPower))
        case .house: return Double(d.loadPower)
        case .ev: return 0
        }
    }

    private func dashNode(_ kind: NodeKind) -> DashNode {
        let d = poller.data
        switch kind {
        case .pv:
            let w = bigWatts(d.pvTotal)
            return DashNode(kind: .pv, name: "SOLAR PV", icon: "sun.max.fill", identity: Palette.pv,
                            semantic: d.pvTotal > 20 ? Semantic.feed : Semantic.idle,
                            magnitude: Double(d.pvTotal), big: w.0, unit: w.1,
                            secondary: String(format: "%.1f kWh today", d.dayPV), feeding: true)
        case .mi:
            let w = bigWatts(d.miPower)
            return DashNode(kind: .mi, name: "MI · HUAWEI", icon: "sun.horizon.fill", identity: Palette.mi,
                            semantic: abs(d.miPower) > 20 ? Semantic.feed : Semantic.idle,
                            magnitude: Double(abs(d.miPower)), big: w.0, unit: w.1,
                            secondary: "AC-coupled PV", feeding: true)
        case .grid:
            let w = bigWatts(d.gridPower)
            let importing = d.gridImporting, exporting = d.gridExporting
            return DashNode(kind: .grid, name: "GRID", icon: "bolt.horizontal.fill", identity: Palette.gridExport,
                            semantic: importing ? Semantic.draw : (exporting ? Semantic.exportTeal : Semantic.idle),
                            magnitude: Double(abs(d.gridPower)), big: w.0, unit: w.1,
                            secondary: String(format: "↓%.1f  ↑%.1f kWh", d.dayGridImport, d.dayGridExport),
                            feeding: importing)
        case .battery:
            let charging = d.batteryCharging, discharging = d.batteryDischarging
            return DashNode(kind: .battery, name: "BATTERY", icon: batterySymbol(d.soc), identity: Palette.batteryDischarge,
                            semantic: discharging ? Semantic.feed : (charging ? Semantic.draw : Semantic.idle),
                            magnitude: Double(abs(d.batteryPower)), big: "\(d.soc)", unit: "%",
                            secondary: String(format: "%d W · %.1f V · %@", abs(d.batteryPower), d.batteryVoltage,
                                              charging ? "charging" : (discharging ? "discharging" : "idle")),
                            feeding: discharging)
        case .house:
            let w = bigWatts(d.loadPower)
            return DashNode(kind: .house, name: "HOUSE", icon: "house.fill", identity: Palette.house,
                            semantic: d.loadPower > 20 ? Semantic.draw : Semantic.idle,
                            magnitude: Double(d.loadPower), big: w.0, unit: w.1,
                            secondary: String(format: "%.1f kWh today", d.dayLoad), feeding: false)
        case .ev:
            return DashNode(kind: .ev, name: "EV", icon: "car.fill", identity: Palette.ev,
                            semantic: Semantic.idle, magnitude: 0, big: "—", unit: "",
                            secondary: "waiting", feeding: false)
        }
    }

    private func tier(_ kind: NodeKind, active: Set<NodeKind>, maxActive: Double, mag: Double) -> Tier {
        if active.isEmpty { return .active }          // all idle -> neutral compacts (never looks broken)
        guard active.contains(kind) else { return .idle }
        return mag >= 0.4 * maxActive ? .hero : .active
    }

    private func tierHeight(_ t: Tier) -> CGFloat {
        switch t {
        case .hero: return sc(86)
        case .active: return sc(70)
        case .idle: return sc(24)
        }
    }

    /// Demote the smallest-|W| non-idle card one tier until the column content
    /// (heights + min gaps) fits `availH`, so it never crosses the bottom bar.
    private func fitTiers(_ items: [(tier: Tier, mag: Double)], availH: CGFloat) -> [Tier] {
        var tiers = items.map { $0.tier }
        let n = tiers.count
        let minGap = sc(8)
        func total() -> CGFloat { tiers.map { tierHeight($0) }.reduce(0, +) + CGFloat(max(0, n - 1)) * minGap }
        while total() > availH {
            var idx = -1
            var best = Double.infinity
            for i in tiers.indices where tiers[i] != .idle {
                if items[i].mag < best { best = items[i].mag; idx = i }
            }
            if idx < 0 { break }
            tiers[idx] = tiers[idx] == .hero ? .active : .idle
        }
        return tiers
    }

    /// Fluid layout: top-aligned, items distributed across `availH` with equal
    /// flexible gaps (min 8pt). A proportional compress is a final safety net.
    private func columnLayout(_ tiers: [Tier], availH: CGFloat) -> [(h: CGFloat, cy: CGFloat)] {
        var heights = tiers.map { tierHeight($0) }
        let n = heights.count
        let minGap = sc(8)
        let gapSpan = CGFloat(max(0, n - 1)) * minGap
        let sumH = heights.reduce(0, +)
        if sumH + gapSpan > availH && sumH > 0 {
            let f = max(availH - gapSpan, 1) / sumH
            heights = heights.map { $0 * f }
        }
        let newSum = heights.reduce(0, +)
        let gap = n > 1 ? max(minGap, (availH - newSum) / CGFloat(n - 1)) : 0
        var result: [(CGFloat, CGFloat)] = []
        var y: CGFloat = 0
        for i in heights.indices {
            result.append((heights[i], y + heights[i] / 2))
            y += heights[i] + gap
        }
        return result
    }

    private struct Placement { let cx: CGFloat; let cy: CGFloat; let hgt: CGFloat; let tier: Tier }

    /// Compute per-node placement (column x, center y, height, tier) for the
    /// current data. Kept out of the ViewBuilder so it can use loops. Battery
    /// migrates columns per `poller.batteryOnRight`.
    private func dashPlacement(w: CGFloat, h: CGFloat, colW: CGFloat,
                               leftCX: CGFloat, rightCX: CGFloat) -> [NodeKind: Placement] {
        let d = poller.data
        let active = poller.activeNodes
        let maxActive = max(active.map { magnitudeOf($0, d) }.max() ?? 1, 1)
        let bottomInset = sc(12)                 // hard gap before the stat bar
        let usableH = max(h - bottomInset, 1)

        let leftKinds: [NodeKind] = poller.batteryOnRight ? [.pv, .mi, .grid] : [.pv, .mi, .grid, .battery]
        let rightKinds: [NodeKind] = poller.batteryOnRight ? [.house, .battery, .ev] : [.house, .ev]

        func items(_ kinds: [NodeKind]) -> [(tier: Tier, mag: Double)] {
            kinds.map { (tier($0, active: active, maxActive: maxActive, mag: magnitudeOf($0, d)),
                         magnitudeOf($0, d)) }
        }
        let lt = fitTiers(items(leftKinds), availH: usableH)
        let rt = fitTiers(items(rightKinds), availH: usableH)
        let ll = columnLayout(lt, availH: usableH)
        let rl = columnLayout(rt, availH: usableH)

        var place: [NodeKind: Placement] = [:]
        for (i, k) in leftKinds.enumerated() { place[k] = Placement(cx: leftCX, cy: ll[i].cy, hgt: ll[i].h, tier: lt[i]) }
        for (i, k) in rightKinds.enumerated() { place[k] = Placement(cx: rightCX, cy: rl[i].cy, hgt: rl[i].h, tier: rt[i]) }
        return place
    }

    private var dashboardView: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, sc(20))
                .padding(.top, sc(14))
                .padding(.bottom, sc(6))
            dashboardBody
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
            dashboardBottomBar
                .padding(.horizontal, sc(20))
                .padding(.top, sc(13))    // +4 breathing above the hairline
                .padding(.bottom, sc(9))
        }
        .animation(.spring(duration: 0.6, bounce: 0.15), value: poller.activeNodes)
        .animation(.spring(duration: 0.55, bounce: 0.1), value: poller.batteryOnRight)
    }

    private var dashboardBody: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let outer = sc(20)                       // symmetric side margins
            let corridor = sc(170)                   // wide corridor -> long flow wires (cards keep width)
            let colW = (w - 2 * outer - corridor) / 2
            let leftCX = outer + colW / 2
            let rightCX = w - outer - colW / 2
            let center = CGPoint(x: w / 2, y: h / 2)
            let place = dashPlacement(w: w, h: h, colW: colW, leftCX: leftCX, rightCX: rightCX)
            // Snapshot everything the 30 fps Canvas needs here, in the view body:
            // this runs on data/layout changes only, so the frame closure never
            // touches the poller or reformats a string.
            let nodes = Dictionary(uniqueKeysWithValues: NodeKind.allCases.map { ($0, dashNode($0)) })
            let activeSet = poller.activeNodes
            let sprites = nodes.mapValues {
                GlowSprite.image(color: $0.semantic, r: sc(2.5), blur: sc(3),
                                 displayScale: displayScale)
            }
            let dots = spineDotSpecs(place: place, nodes: nodes, activeSet: activeSet,
                                     sprites: sprites, center: center, colW: colW)

            ZStack {
                // Static spines: geometry/width/color change only with poller data
                // or layout, so they redraw on body evaluation (~per poll), not per
                // animation frame.
                Canvas { ctx, _ in
                    for k in NodeKind.allCases {
                        guard let p = place[k], let n = nodes[k] else { continue }
                        let onLeft = p.cx < center.x
                        let edge = CGPoint(x: onLeft ? p.cx + colW / 2 : p.cx - colW / 2, y: p.cy)
                        drawSpineStroke(ctx: ctx, cardEdge: edge, center: center,
                                        node: n, tier: p.tier, isActive: activeSet.contains(k))
                    }
                }
                // ponytail: the dots are CALayers animated by the render server, so
                // the app does no per-frame work. No active spine -> empty specs ->
                // no layers, nothing animating.
                if !Self.offscreen {
                    DotLayerView(specs: dots, displayScale: displayScale)
                        .allowsHitTesting(false)
                }

                inverterNode.position(center)

                ForEach(NodeKind.allCases, id: \.self) { k in
                    if let p = place[k], let n = nodes[k] {
                        tierView(n, tier: p.tier)
                            .frame(width: colW, height: p.hgt)
                            .position(x: p.cx, y: p.cy)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func tierView(_ n: DashNode, tier: Tier) -> some View {
        if tier == .idle {
            idleRow(n)
        } else {
            dashTierCard(n, hero: tier == .hero)
        }
    }

    private func idleRow(_ n: DashNode) -> some View {
        HStack(spacing: sc(8)) {
            Image(systemName: n.icon)
                .font(.system(size: sc(16), weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(n.identity.opacity(0.7))
            Text(n.name)
                .font(.system(size: sc(10), weight: .semibold, design: .rounded))
                .tracking(sc(0.6))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            // E2 on the Dashboard: at the floor the battery is idle, so say why here.
            if n.kind == .battery, case .reserve = poller.batteryETA, let t = flowETALine {
                Text(t)
                    .font(.system(size: sc(10), weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Text(n.kind == .ev ? "waiting" : (n.unit.isEmpty ? n.big : "\(n.big) \(n.unit)"))
                .font(.system(size: sc(11), weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, sc(10))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .opacity(0.55)
    }

    @ViewBuilder
    private func dashTierCard(_ n: DashNode, hero: Bool) -> some View {
        let active = poller.activeNodes.contains(n.kind)
        let badge = hero ? sc(52) : sc(40)
        let iconSize = hero ? sc(30) : sc(23)
        let valueSize = hero ? sc(34) : sc(24)
        let tint = active ? n.semantic : Semantic.idle
        let frac = min(1.0, n.magnitude / 3000.0)
        let glow = active ? sc(2 + 6 * frac) : 0

        HStack(spacing: sc(10)) {
            ZStack {
                Circle()
                    .fill(n.identity.opacity(0.14))
                    .overlay(Circle().stroke(n.identity.opacity(active ? 0.4 : 0.15), lineWidth: 1))
                    .frame(width: badge, height: badge)
                    .shadow(color: active ? tint.opacity(0.5) : .clear, radius: glow)
                Image(systemName: n.icon)
                    .font(.system(size: iconSize, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(active ? n.identity : Color.secondary)
            }
            VStack(alignment: .leading, spacing: sc(1)) {
                Text(n.name)
                    .font(.system(size: sc(9), weight: .semibold, design: .rounded))
                    .tracking(sc(0.8))
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: sc(3)) {
                    Text(n.big)
                        .font(.system(size: valueSize, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .foregroundStyle(active ? tint : Color.primary)
                    if !n.unit.isEmpty {
                        Text(n.unit)
                            .font(.system(size: hero ? sc(15) : sc(12), weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
                if n.kind == .battery {
                    socBar(tint: active ? tint : Semantic.idle)
                }
                if n.kind == .battery, let e = etaText(hero: hero) {
                    (Text(e.lead).fontWeight(.semibold).foregroundColor(.primary)
                     + Text(e.tail.map { " · \($0)" } ?? "").foregroundColor(.secondary))
                        .font(.system(size: sc(11), weight: .regular, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    if let pill = e.pill {
                        Text(pill.text)
                            .font(.system(size: sc(9.5), weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(pill.color)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .padding(.horizontal, sc(6))
                            .padding(.vertical, sc(1.5))
                            .background(Capsule().fill(pill.color.opacity(0.16)))
                    }
                } else {
                    Text(n.secondary)
                        .font(.system(size: sc(11), weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, sc(16))
        .padding(.vertical, sc(12))
        .background(
            RoundedRectangle(cornerRadius: sc(16), style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: sc(16), style: .continuous).fill(tint.opacity(active ? 0.08 : 0)))
                .overlay(RoundedRectangle(cornerRadius: sc(16), style: .continuous)
                    .stroke(tint.opacity(active ? (hero ? 0.55 : 0.35) : 0.12), lineWidth: hero ? 1.5 : 1))
        )
    }

    /// C2: SOC bar under the battery value. The part below the floor (the
    /// inverter's reserve) is dimmed, with a thin white tick at the floor.
    private func socBar(tint: Color) -> some View {
        let soc = min(max(Double(poller.data.soc) / 100, 0), 1)
        let floor = min(max(settings.batteryFloor / 100, 0), 1)
        return Canvas { ctx, size in
            let r = size.height / 2
            let full = CGRect(origin: .zero, size: size)
            ctx.fill(Path(roundedRect: full, cornerRadius: r), with: .color(.white.opacity(0.10)))
            var fill = ctx
            fill.clip(to: Path(roundedRect: full, cornerRadius: r))
            let low = min(soc, floor) * size.width
            fill.fill(Path(CGRect(x: 0, y: 0, width: low, height: size.height)), with: .color(tint.opacity(0.35)))
            if soc > floor {
                fill.fill(Path(CGRect(x: low, y: 0, width: (soc - floor) * size.width, height: size.height)),
                          with: .color(tint))
            }
            let x = floor * size.width
            fill.fill(Path(CGRect(x: x - 0.75, y: 0, width: 1.5, height: size.height)), with: .color(.white.opacity(0.9)))
        }
        .frame(height: sc(6))
        .padding(.vertical, sc(2))
    }

    private struct ETAText {
        let lead: String
        let tail: String?
        let pill: (text: String, color: Color)?
    }

    private func kw(_ w: Int) -> String {
        abs(w) >= 1000 ? String(format: "%.1f kW", Double(abs(w)) / 1000) : "\(abs(w)) W"
    }

    /// Dashboard battery-card text for the current estimate; nil → old subtitle.
    /// Hero cards get the B3 pill; smaller cards fold the solar time inline.
    private func etaText(hero: Bool) -> ETAText? {
        let hm = { (d: Date) in BatteryEstimate.clock.string(from: d) }
        switch poller.batteryETA {
        case .none:
            return nil
        case .charging(let fullBy):
            return ETAText(lead: "full by \(hm(fullBy))", tail: kw(poller.data.batteryPower), pill: nil)
        case .reserve(let since):
            return ETAText(lead: since.map { "on grid since \(hm($0))" } ?? "on grid", tail: nil, pill: nil)
        case .discharging(let until, let solarAt, let learning):
            let sun = solarAt.map { "☀ ~\(hm($0))" }
            let lead = until.map { "until \(hm($0))" } ?? (solarAt == nil ? "lasts 36 h+" : "lasts until solar")
            if learning {
                return hero ? ETAText(lead: lead, tail: sun, pill: ("learning…", Semantic.idle))
                            : ETAText(lead: lead, tail: "learning", pill: nil)
            }
            guard hero, let solarAt, let sun else { return ETAText(lead: lead, tail: sun, pill: nil) }
            guard let until else {   // lasts: green pill, same shape as the grid one
                return ETAText(lead: lead, tail: nil, pill: ("\(sun) · no grid", Palette.batteryCharge))
            }
            let gap = solarAt.timeIntervalSince(until)
            let gapText = gap >= 3600 ? String(format: "%.1f h grid", gap / 3600) : "\(Int(gap / 60)) min grid"
            return ETAText(lead: lead, tail: nil, pill: ("\(sun) · \(gapText)", Palette.batteryDischarge))
        }
    }

    /// Flow-mode third line under the battery node (D1); nil hides it. Reserve
    /// says "grid since" (not "on grid since"): the battery node sits ~50 pt from
    /// the left edge, and the longer form ran past it at Small scale.
    private var flowETALine: String? {
        let hm = { (d: Date) in BatteryEstimate.clock.string(from: d) }
        switch poller.batteryETA {
        case .none: return nil
        case .charging(let fullBy): return "full by \(hm(fullBy))"
        case .reserve(let since): return since.map { "grid since \(hm($0))" } ?? "on grid"
        case .discharging(let until, let solarAt, _):
            return until.map { "until \(hm($0))" } ?? (solarAt == nil ? "lasts 36 h+" : "lasts until solar")
        }
    }

    /// Bézier control points of the spine running from a card edge to the
    /// inverter. Shared by the static stroke and the animated dots so both halves
    /// trace exactly the same curve.
    private func spineGeometry(cardEdge: CGPoint, center: CGPoint)
        -> (s: CGPoint, e: CGPoint, c1: CGPoint, c2: CGPoint) {
        let s = cardEdge
        let e = edgePoint(from: center, to: cardEdge, radius: invR)
        let radial = unit(dx: cardEdge.x - center.x, dy: cardEdge.y - center.y)
        let span = hypot(e.x - s.x, e.y - s.y)
        let c1 = CGPoint(x: s.x + (e.x - s.x) * 0.5, y: s.y)
        let c2 = CGPoint(x: e.x + radial.dx * span * 0.4, y: e.y + radial.dy * span * 0.4)
        return (s, e, c1, c2)
    }

    /// Static half of the spine: the |W|-scaled glowing stroke.
    private func drawSpineStroke(ctx: GraphicsContext, cardEdge: CGPoint, center: CGPoint,
                                 node: DashNode, tier: Tier, isActive: Bool) {
        let g = spineGeometry(cardEdge: cardEdge, center: center)

        let active = isActive && tier != .idle
        let color = active ? node.semantic : Semantic.idle
        let frac = min(1.0, node.magnitude / 3000.0)
        let width = active ? (1.5 + 2.5 * frac) : 1.0

        var path = Path()
        path.move(to: g.s)
        path.addCurve(to: g.e, control1: g.c1, control2: g.c2)
        ctx.stroke(path,
                   with: .color(active ? color.opacity(0.65) : Color.white.opacity(0.07)),
                   style: StrokeStyle(lineWidth: sc(width), lineCap: .round))
    }

    /// Animated half of the spine, handed to Core Animation instead of drawn:
    /// one DotSpec per active spine. dotCount/period/travel-window formulas are
    /// verbatim from the old per-frame loop.
    private func spineDotSpecs(place: [NodeKind: Placement], nodes: [NodeKind: DashNode],
                               activeSet: Set<NodeKind>, sprites: [NodeKind: NSImage],
                               center: CGPoint, colW: CGFloat) -> [DotSpec] {
        var out: [DotSpec] = []
        for k in NodeKind.allCases {
            guard let p = place[k], let n = nodes[k], let sprite = sprites[k] else { continue }
            guard activeSet.contains(k), p.tier != .idle else { continue }
            let onLeft = p.cx < center.x
            let edge = CGPoint(x: onLeft ? p.cx + colW / 2 : p.cx - colW / 2, y: p.cy)
            let g = spineGeometry(cardEdge: edge, center: center)
            let frac = min(1.0, n.magnitude / 3000.0)
            // travel = 0.08 + phase * 0.84; feeding = node -> inverter.
            out.append(DotSpec(id: k.rawValue,
                               points: travelSamples(g, from: 0.08, to: 0.92, reversed: !n.feeding),
                               dotCount: max(1, Int((1 + 3 * frac).rounded())),
                               period: 2.5 - 1.6 * frac,
                               sprite: sprite, side: sprite.size.width))
        }
        return out
    }

    /// Samples per travel window. 32 keeps the chord error of the polyline far
    /// below a point, so linear interpolation between samples is invisible.
    private static let dotSamples = 32

    /// The curve at equal Bézier-parameter steps across the travel window. Equal
    /// u steps are the point: Core Animation walks the values at a constant rate,
    /// which reproduces the old parameter-speed pacing rather than arc-length.
    private func travelSamples(_ g: (s: CGPoint, e: CGPoint, c1: CGPoint, c2: CGPoint),
                               from u0: Double, to u1: Double, reversed: Bool) -> [CGPoint] {
        let n = Self.dotSamples
        var pts: [CGPoint] = []
        pts.reserveCapacity(n)
        for j in 0..<n {
            let u = u0 + (u1 - u0) * Double(j) / Double(n - 1)
            pts.append(cubicPoint(CGFloat(u), g.s, g.c1, g.c2, g.e))
        }
        return reversed ? pts.reversed() : pts
    }

    private var dashboardBottomBar: some View {
        let d = poller.data
        let freqOK = d.gridFrequency >= 45 && d.gridFrequency <= 65
        return HStack(spacing: 0) {
            bottomStat("bolt.fill", Palette.gridImport, "VOLTAGE", String(format: "%.1f V", d.gridVoltage))
            bottomStat("battery.100", Palette.batteryCharge, "BATTERY", String(format: "%.2f V", d.batteryVoltage))
            bottomStat("waveform.path", Palette.mi, "FREQUENCY", freqOK ? String(format: "%.1f Hz", d.gridFrequency) : "—")
            bottomStat("thermometer", Palette.batteryDischarge, "TEMP", String(format: "%.1f °C", d.inverterTemp))
        }
    }

    private func bottomStat(_ icon: String, _ tint: Color, _ caption: String, _ value: String) -> some View {
        HStack(spacing: sc(6)) {
            Image(systemName: icon)
                .font(.system(size: sc(13), weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 0) {
                Text(caption)
                    .font(.system(size: sc(8), weight: .semibold, design: .rounded))
                    .foregroundStyle(.tertiary)
                Text(value)
                    .font(.system(size: sc(12), weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var anyActive: Bool {
        let d = poller.data
        return d.pvTotal > 20 || abs(d.miPower) > 20 || d.gridImporting || d.gridExporting
            || d.batteryCharging || d.batteryDischarging || d.loadPower > 20
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: sc(9)) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(colors: [Color.yellow, Color.orange],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .frame(width: sc(22), height: sc(22))
                    .shadow(color: .yellow.opacity(0.5), radius: sc(3))
                Image(systemName: "bolt.fill")
                    .font(.system(size: sc(11), weight: .bold))
                    .foregroundStyle(.white)
            }
            Text("Deye 8 kW")
                .font(.system(size: sc(15), weight: .semibold, design: .rounded))
            Spacer()
            Text(relativeUpdate)
                .font(.system(size: sc(10), weight: .regular, design: .rounded))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            BreathingDot(connected: poller.connected, scale: scale)
        }
    }

    private var relativeUpdate: String {
        if poller.notConfigured { return "not configured — Settings…" }
        guard let d = poller.lastUpdate else { return "connecting…" }
        let secs = Int(Date().timeIntervalSince(d))
        if secs < 2 { return "updated just now" }
        if secs < 60 { return "updated \(secs) s ago" }
        let m = secs / 60
        return "updated \(m) min ago"
    }

    // MARK: Flow area

    private var flowArea: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let center = CGPoint(x: w / 2, y: h / 2)

            // Circle centers. Top nodes near the top; bottom nodes leave room
            // beneath for two label lines above the stats strip.
            let topY = nodeR + sc(4)
            // The battery's time-left line (D1) needs ~one more label row.
            let etaLift = flowETALine == nil ? 0 : sc(14)
            let botY = h - nodeR - sc(42) - etaLift
            let leftX = nodeR + sc(12)
            let rightX = w - nodeR - sc(12)
            let midX = w / 2

            let pvPos = CGPoint(x: leftX, y: topY)
            let miPos = CGPoint(x: midX, y: topY)
            let gridPos = CGPoint(x: rightX, y: topY)
            let battPos = CGPoint(x: leftX, y: botY)
            let housePos = CGPoint(x: midX, y: botY)
            let evPos = CGPoint(x: rightX, y: botY)

            let d = poller.data
            let positions = [pvPos, miPos, gridPos, battPos, housePos, evPos]
            let specs = [pvNode(d), miNode(d), gridNode(d), battNode(d), houseNode(d), evNode(d)]
            let sprites = specs.map {
                GlowSprite.image(color: $0.color, r: sc(2.5), blur: sc(3),
                                 displayScale: displayScale)
            }
            let dots = connectionDotSpecs(positions: positions, specs: specs,
                                          sprites: sprites, center: center)

            ZStack {
                // Static connector curves: they change only with poller data or
                // layout, so they redraw on body evaluation, not per animation
                // frame. Same coordinate space as the dot canvas below.
                Canvas { ctx, _ in
                    for i in 0..<6 {
                        drawConnectionStroke(ctx: ctx, node: positions[i], center: center,
                                             spec: specs[i])
                    }
                }
                // ponytail: the dots are CALayers animated by the render server, so
                // the app does no per-frame work. No active connector -> empty specs
                // -> no layers, nothing animating.
                if !Self.offscreen {
                    DotLayerView(specs: dots, displayScale: displayScale)
                        .allowsHitTesting(false)
                }

                inverterNode.position(center)

                // Circles sit exactly on the connector anchor points.
                ForEach(0..<6, id: \.self) { i in
                    nodeCircle(specs[i]).position(positions[i])
                }
                // Labels below each circle.
                ForEach(0..<6, id: \.self) { i in
                    nodeLabels(specs[i])
                        .position(x: positions[i].x,
                                  y: positions[i].y + nodeR + sc(20) + (specs[i].tertiary == nil ? 0 : sc(7)))
                }
            }
        }
    }

    private var inverterNode: some View {
        let active = anyActive
        // The material + shadows below are static. Keeping them out of a
        // per-frame TimelineView body stops SwiftUI recycling their backing
        // IOSurfaces 60x/s (RenderBox SurfacePool churn).
        return ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1))
                .frame(width: invR * 2, height: invR * 2)
                .shadow(color: .black.opacity(0.35), radius: sc(6), y: sc(2))
            Image(systemName: "bolt.fill")
                .font(.system(size: sc(24), weight: .bold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.yellow)
                .shadow(color: active ? .yellow.opacity(0.5) : .clear, radius: sc(6))
        }
        // Was 1.0 + 0.03 * (sin(2t)+1)/2 -> period 2pi/2 = 3.14 s, half-cycle 1.57 s.
        .scaleEffect(active && breathing ? 1.03 : 1.0)
        .animation(.easeInOut(duration: 1.57).repeatForever(autoreverses: true), value: breathing)
        .onAppear { breathing = true }
    }

    // MARK: Node specs

    private func pvNode(_ d: InverterData) -> Node {
        let active = d.pvTotal > 20
        return Node(symbol: "sun.max.fill", name: "PV", value: Fmt.watts(d.pvTotal),
                    secondary: nil, color: Palette.pv,
                    dir: active ? .toInverter : .none, active: active, socPrimary: false)
    }

    private func miNode(_ d: InverterData) -> Node {
        let active = abs(d.miPower) > 20
        return Node(symbol: "sun.horizon.fill", name: "MI", value: Fmt.watts(d.miPower),
                    secondary: "Huawei", color: Palette.mi,
                    dir: d.miPower > 20 ? .toInverter : .none, active: active, socPrimary: false)
    }

    private func gridNode(_ d: InverterData) -> Node {
        let importing = d.gridImporting
        let exporting = d.gridExporting
        let color = importing ? Palette.gridImport : (exporting ? Palette.gridExport : Palette.idle)
        return Node(symbol: "bolt.horizontal.fill", name: "Grid", value: Fmt.watts(d.gridPower),
                    secondary: importing ? "import" : (exporting ? "export" : "idle"),
                    color: color,
                    dir: importing ? .toInverter : (exporting ? .fromInverter : .none),
                    active: importing || exporting, socPrimary: false)
    }

    private func battNode(_ d: InverterData) -> Node {
        let charging = d.batteryCharging
        let discharging = d.batteryDischarging
        let color = charging ? Palette.batteryCharge : (discharging ? Palette.batteryDischarge : Palette.idle)
        return Node(symbol: batterySymbol(d.soc), name: "Battery", value: "\(d.soc)%",
                    secondary: Fmt.watts(d.batteryPower), color: color,
                    dir: discharging ? .toInverter : (charging ? .fromInverter : .none),
                    active: charging || discharging, socPrimary: true, tertiary: flowETALine)
    }

    private func houseNode(_ d: InverterData) -> Node {
        let active = d.loadPower > 20
        return Node(symbol: "house.fill", name: "House", value: Fmt.watts(d.loadPower),
                    secondary: "UPS", color: Palette.house,
                    dir: active ? .fromInverter : .none, active: active, socPrimary: false)
    }

    private func evNode(_ d: InverterData) -> Node {
        Node(symbol: "car.fill", name: "EV", value: "—", secondary: nil,
             color: Palette.ev, dir: .none, active: false, socPrimary: false)
    }

    private func batterySymbol(_ soc: Int) -> String {
        switch soc {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default: return "battery.100"
        }
    }

    // MARK: Node view (circle + labels, positioned separately)

    @ViewBuilder
    private func nodeCircle(_ n: Node) -> some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .overlay(Circle().stroke(Color.white.opacity(0.15), lineWidth: 1))
                .frame(width: nodeR * 2, height: nodeR * 2)
                .shadow(color: n.active ? n.color.opacity(0.55) : .black.opacity(0.25),
                        radius: n.active ? sc(8) : sc(3), y: sc(1))
            Image(systemName: n.symbol)
                .font(.system(size: sc(19), weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(n.active ? n.color : Color.secondary)
        }
        .opacity(n.name == "EV" && !n.active ? 0.30 : 1.0)
    }

    @ViewBuilder
    private func nodeLabels(_ n: Node) -> some View {
        VStack(spacing: sc(2)) {
            if n.socPrimary {
                Text(n.value)
                    .font(.system(size: sc(20), weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                if let s = n.secondary {
                    Text(s)
                        .font(.system(size: sc(10), weight: .semibold, design: .rounded))
                        .foregroundStyle(n.active ? .primary : .secondary)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                if let t = n.tertiary {
                    Text(t)
                        .font(.system(size: sc(10), weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            } else {
                Text(n.name)
                    .font(.system(size: sc(10), weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary)
                Text(n.value)
                    .font(.system(size: sc(15), weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(n.name == "EV" && !n.active ? Color.secondary : .primary)
            }
        }
        .fixedSize()
    }

    // MARK: Connectors (Canvas-drawn)

    /// Bézier control points of the connector running from a node to the
    /// inverter. Shared by the static stroke and the animated dots so both halves
    /// trace exactly the same curve.
    private func connectionGeometry(node: CGPoint, center: CGPoint)
        -> (s: CGPoint, e: CGPoint, c1: CGPoint, c2: CGPoint) {
        // Curve always drawn node -> inverter for geometric stability.
        let s = edgePoint(from: node, to: center, radius: nodeR)
        let e = edgePoint(from: center, to: node, radius: invR)
        // Tangent-aligned control handles, no inflection: the curve leaves the
        // node vertically, then eases into the inverter along the radial line
        // node->center so it meets the inverter circle smoothly (no kink).
        let span = hypot(e.x - s.x, e.y - s.y)
        let handle = span * 0.4
        let radial = unit(dx: node.x - center.x, dy: node.y - center.y)
        let c1 = CGPoint(x: s.x, y: s.y + (e.y - s.y) * 0.5)         // vertical leave
        let c2 = CGPoint(x: e.x + radial.dx * handle,               // radial ease-in
                         y: e.y + radial.dy * handle)
        return (s, e, c1, c2)
    }

    /// Static half of the connector: the curve itself.
    private func drawConnectionStroke(ctx: GraphicsContext, node: CGPoint, center: CGPoint,
                                      spec: Node) {
        let g = connectionGeometry(node: node, center: center)
        let active = spec.active && spec.dir != .none

        var path = Path()
        path.move(to: g.s)
        path.addCurve(to: g.e, control1: g.c1, control2: g.c2)
        ctx.stroke(
            path,
            with: .color(active ? spec.color.opacity(0.6) : Color.white.opacity(0.08)),
            style: StrokeStyle(lineWidth: active ? sc(2) : sc(1), lineCap: .round)
        )
    }

    /// Animated half of the connector, handed to Core Animation instead of drawn.
    /// ~2 s per traversal; 3 evenly phased dots on the visible mid-path.
    private func connectionDotSpecs(positions: [CGPoint], specs: [Node],
                                    sprites: [NSImage], center: CGPoint) -> [DotSpec] {
        var out: [DotSpec] = []
        for i in 0..<6 {
            let spec = specs[i]
            guard spec.active, spec.dir != .none else { continue }
            let g = connectionGeometry(node: positions[i], center: center)
            // travel = 0.1 + phase * 0.8, run backwards unless the flow is inbound.
            out.append(DotSpec(id: "conn-\(i)",
                               points: travelSamples(g, from: 0.1, to: 0.9,
                                                     reversed: spec.dir != .toInverter),
                               dotCount: 3, period: 2.0,
                               sprite: sprites[i], side: sprites[i].size.width))
        }
        return out
    }

    private func edgePoint(from: CGPoint, to: CGPoint, radius: CGFloat) -> CGPoint {
        let dx = to.x - from.x
        let dy = to.y - from.y
        let len = max(sqrt(dx * dx + dy * dy), 0.001)
        return CGPoint(x: from.x + dx / len * radius, y: from.y + dy / len * radius)
    }

    private func unit(dx: CGFloat, dy: CGFloat) -> (dx: CGFloat, dy: CGFloat) {
        let len = max(sqrt(dx * dx + dy * dy), 0.001)
        return (dx / len, dy / len)
    }

    private func cubicPoint(_ t: CGFloat, _ p0: CGPoint, _ c1: CGPoint, _ c2: CGPoint, _ p3: CGPoint) -> CGPoint {
        let mt = 1 - t
        let a = mt * mt * mt
        let b = 3 * mt * mt * t
        let c = 3 * mt * t * t
        let d = t * t * t
        return CGPoint(x: a * p0.x + b * c1.x + c * c2.x + d * p3.x,
                       y: a * p0.y + b * c1.y + c * c2.y + d * p3.y)
    }

    // MARK: Stats strip

    private var statsStrip: some View {
        let d = poller.data
        return VStack(spacing: sc(6)) {
            HStack(alignment: .bottom, spacing: sc(8)) {
                statCapsule(caption: "PV", symbol: "sun.max.fill", tint: Palette.pv) {
                    Text(String(format: "%.1f", d.dayPV))
                }
                statCapsule(caption: "BATT", symbol: "battery.100", tint: Palette.batteryCharge) {
                    HStack(spacing: sc(2)) {
                        Text(String(format: "+%.1f", d.dayBatteryCharge))
                            .foregroundStyle(Palette.batteryCharge)
                        Text("/").foregroundStyle(.secondary)
                        Text(String(format: "−%.1f", d.dayBatteryDischarge))
                            .foregroundStyle(Palette.batteryDischarge)
                    }
                }
                statCapsule(caption: "GRID", symbol: "bolt.horizontal.fill", tint: Palette.gridExport) {
                    HStack(spacing: sc(4)) {
                        HStack(spacing: sc(1)) {
                            Image(systemName: "arrow.down").font(.system(size: sc(8), weight: .bold))
                            Text(String(format: "%.1f", d.dayGridImport))
                        }.foregroundStyle(Palette.gridImport)
                        HStack(spacing: sc(1)) {
                            Image(systemName: "arrow.up").font(.system(size: sc(8), weight: .bold))
                            Text(String(format: "%.1f", d.dayGridExport))
                        }.foregroundStyle(Palette.gridExport)
                    }
                }
                statCapsule(caption: "HOME", symbol: "house.fill", tint: Palette.house) {
                    Text(String(format: "%.1f", d.dayLoad))
                }
                Text("kWh")
                    .font(.system(size: sc(8), weight: .regular, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, sc(3))
            }

            Text(String(format: "%.1f V  ·  %.1f °C  ·  %.2f V batt",
                        d.gridVoltage, d.inverterTemp, d.batteryVoltage))
                .font(.system(size: sc(9), weight: .regular, design: .rounded))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
    }

    @ViewBuilder
    private func statCapsule<Content: View>(caption: String, symbol: String, tint: Color,
                                            @ViewBuilder value: () -> Content) -> some View {
        VStack(spacing: sc(2)) {
            HStack(spacing: sc(3)) {
                Image(systemName: symbol)
                    .font(.system(size: sc(8), weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(tint)
                Text(caption)
                    .font(.system(size: sc(9), weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            value()
                .font(.system(size: sc(12), weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.vertical, sc(6))
        .padding(.horizontal, sc(8))
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: sc(8), style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: sc(8), style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1))
        )
    }
}

// MARK: - Chart pane (Power Profile)

/// Live rolling power-history chart shown to the right of the flow graph.
struct ChartPane: View {
    @ObservedObject var poller: DataPoller
    var scale: CGFloat = 1.0

    private func sc(_ v: CGFloat) -> CGFloat { v * scale }

    var body: some View {
        VStack(alignment: .leading, spacing: sc(6)) {
            HStack(alignment: .firstTextBaseline) {
                Text("Power Profile")
                    .font(.system(size: sc(13), weight: .semibold, design: .rounded))
                Spacer()
                Text("last 60 min")
                    .font(.system(size: sc(9), weight: .regular, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
            legend
            chart
        }
        .padding(sc(14))
    }

    private var legend: some View {
        HStack(spacing: sc(9)) {
            legendItem(Palette.house, "House")
            legendItem(Palette.mi, "MI")
            legendItem(Palette.batteryDischarge, "Batt")
            legendItem(Palette.gridImport, "Grid")
            legendItem(Color.white.opacity(0.55), "SOC")
        }
    }

    private func legendItem(_ color: Color, _ label: String) -> some View {
        HStack(spacing: sc(3)) {
            Circle().fill(color).frame(width: sc(6), height: sc(6))
            Text(label)
                .font(.system(size: sc(9), weight: .regular, design: .rounded))
                .foregroundStyle(.secondary)
        }
    }

    private var chart: some View {
        let samples = poller.history
        return ZStack {
            RoundedRectangle(cornerRadius: sc(10), style: .continuous)
                .fill(Color.black.opacity(0.18))
                .overlay(RoundedRectangle(cornerRadius: sc(10), style: .continuous)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1))

            if samples.count <= 2 {
                Text("collecting…")
                    .font(.system(size: sc(11), weight: .regular, design: .rounded))
                    .foregroundStyle(.tertiary)
            } else {
                Canvas { ctx, size in
                    drawChart(ctx: ctx, size: size, samples: samples)
                }
                .padding(sc(8))
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func drawChart(ctx: GraphicsContext, size: CGSize, samples: [PowerSample]) {
        let pad = sc(4)
        let now = Date()
        let windowSec: Double = 3600
        // Span from the earliest available sample (capped at 60 min ago) to now,
        // so the data fills the pane immediately and becomes a rolling 60-min
        // window once more than an hour of history exists.
        let earliest = samples.first?.time ?? now
        let x0 = max(now.addingTimeInterval(-windowSec), earliest)
        let span = max(now.timeIntervalSince(x0), 1)
        let xFor: (Date) -> CGFloat = { CGFloat($0.timeIntervalSince(x0) / span) * size.width }

        let maxAbs = max(
            samples.map { max(abs($0.house), abs($0.mi), abs($0.battery), abs($0.grid)) }.max() ?? 100,
            100
        )
        let usableH = size.height - 2 * pad
        let midY = size.height / 2
        let yW: (Double) -> CGFloat = { midY - CGFloat($0 / maxAbs) * (usableH / 2) }
        let ySoc: (Double) -> CGFloat = { (size.height - pad) - CGFloat($0 / 100) * usableH }

        // Zero-watts baseline.
        var zero = Path()
        zero.move(to: CGPoint(x: 0, y: midY))
        zero.addLine(to: CGPoint(x: size.width, y: midY))
        ctx.stroke(zero, with: .color(.white.opacity(0.10)),
                   style: StrokeStyle(lineWidth: 1, dash: [sc(3), sc(3)]))

        func series(_ value: (PowerSample) -> Double, _ color: Color,
                    _ yf: (Double) -> CGFloat, glow: Bool = true, width: CGFloat = 1.5) {
            var p = Path()
            for (i, s) in samples.enumerated() {
                let pt = CGPoint(x: xFor(s.time), y: yf(value(s)))
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            let style = StrokeStyle(lineWidth: sc(width), lineCap: .round, lineJoin: .round)
            if glow {
                ctx.drawLayer { layer in
                    layer.addFilter(.shadow(color: color.opacity(0.5), radius: sc(2)))
                    layer.stroke(p, with: .color(color), style: style)
                }
            } else {
                ctx.stroke(p, with: .color(color), style: style)
            }
        }

        // SOC first (behind), thin white; then the four power series on top.
        series({ $0.soc }, Color.white.opacity(0.5), ySoc, glow: false, width: 1.0)
        series({ $0.house }, Palette.house, yW)
        series({ $0.mi }, Palette.mi, yW)
        series({ $0.grid }, Palette.gridImport, yW)
        series({ $0.battery }, Palette.batteryDischarge, yW)
    }
}

// MARK: - Shapes / helpers

/// Green (connected) or red (disconnected) status dot; connected one breathes.
struct BreathingDot: View {
    let connected: Bool
    var scale: CGFloat = 1.0

    @State private var pulsing = false

    var body: some View {
        // The shadow is composited before .opacity, so animating opacity alone
        // pulses the glow too -- one CA-interpolated property, no per-frame body.
        // Was sin(t * 2.2) -> period 2pi/2.2 = 2.86 s, half-cycle 1.43 s.
        Circle()
            .fill(connected ? Color.green : Color.red)
            .frame(width: 9 * scale, height: 9 * scale)
            .shadow(color: (connected ? Color.green : Color.red).opacity(0.9), radius: 4 * scale)
            .opacity(connected ? (pulsing ? 1.0 : 0.7) : 1.0)
            .animation(.easeInOut(duration: 1.43).repeatForever(autoreverses: true), value: pulsing)
            .onAppear { pulsing = true }
    }
}
