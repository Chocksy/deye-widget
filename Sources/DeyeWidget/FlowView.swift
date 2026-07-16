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
}

// MARK: - FlowView

struct FlowView: View {
    @ObservedObject var poller: DataPoller
    @ObservedObject var settings: Settings
    /// When true, extend the widget to the right with the Power Profile chart.
    var showChart: Bool = true
    /// Uniform size multiplier. All point sizes are parameterized (not
    /// rasterized via scaleEffect) so text stays crisp at every preset.
    var scale: CGFloat = 1.0

    // Base design: 440x400 flow, +330 wide chart pane when shown.
    static let flowWidth: CGFloat = 440
    static let chartWidth: CGFloat = 330
    static let baseHeight: CGFloat = 400

    private var nodeR: CGFloat { 25 * scale }   // node circle radius
    private var invR: CGFloat { 30 * scale }    // inverter circle radius

    /// Scale a base point value.
    private func sc(_ v: CGFloat) -> CGFloat { v * scale }

    /// Total content size for the current configuration.
    static func contentSize(showChart: Bool, scale: CGFloat) -> CGSize {
        let w = (showChart ? flowWidth + chartWidth : flowWidth) * scale
        return CGSize(width: w, height: baseHeight * scale)
    }

    var body: some View {
        ZStack {
            // Dark gradient overlay so content pops on any wallpaper.
            LinearGradient(
                colors: [Color.black.opacity(0.20), Color.black.opacity(0.45)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            if showChart {
                HStack(spacing: 0) {
                    flowColumn
                        .frame(width: sc(Self.flowWidth))
                    Rectangle()
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 1)
                    ChartPane(poller: poller, scale: scale)
                        .frame(width: sc(Self.chartWidth) - 1)
                }
            } else {
                flowColumn.frame(width: sc(Self.flowWidth))
            }
        }
        .frame(width: Self.contentSize(showChart: showChart, scale: scale).width,
               height: Self.contentSize(showChart: showChart, scale: scale).height)
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
            let botY = h - nodeR - sc(42)
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

            ZStack {
                // Connectors (curves + traveling dots) drawn in one Canvas so
                // everything shares the flow-area coordinate space exactly.
                TimelineView(.animation) { timeline in
                    Canvas { ctx, _ in
                        for i in 0..<6 {
                            drawConnection(ctx: ctx, node: positions[i], center: center,
                                           spec: specs[i], date: timeline.date)
                        }
                    }
                }

                inverterNode.position(center)

                // Circles sit exactly on the connector anchor points.
                ForEach(0..<6, id: \.self) { i in
                    nodeCircle(specs[i]).position(positions[i])
                }
                // Labels below each circle.
                ForEach(0..<6, id: \.self) { i in
                    nodeLabels(specs[i])
                        .position(x: positions[i].x, y: positions[i].y + nodeR + sc(20))
                }
            }
        }
    }

    private var inverterNode: some View {
        TimelineView(.animation) { timeline in
            let active = anyActive
            let breath = active ? breathScale(timeline.date) : 1.0
            ZStack {
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
            .scaleEffect(breath)
        }
    }

    private func breathScale(_ date: Date) -> CGFloat {
        let t = date.timeIntervalSinceReferenceDate
        return 1.0 + 0.03 * CGFloat((sin(t * 2.0) + 1) / 2)
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
                    active: charging || discharging, socPrimary: true)
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
                    .font(.system(size: sc(17), weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                if let s = n.secondary {
                    Text(s)
                        .font(.system(size: sc(10), weight: .semibold, design: .rounded))
                        .foregroundStyle(n.active ? .primary : .secondary)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
            } else {
                Text(n.name)
                    .font(.system(size: sc(10), weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary)
                Text(n.value)
                    .font(.system(size: sc(13), weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(n.name == "EV" && !n.active ? Color.secondary : .primary)
            }
        }
        .fixedSize()
    }

    // MARK: Connectors (Canvas-drawn)

    private func drawConnection(ctx: GraphicsContext, node: CGPoint, center: CGPoint,
                                spec: Node, date: Date) {
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

        let active = spec.active && spec.dir != .none

        var path = Path()
        path.move(to: s)
        path.addCurve(to: e, control1: c1, control2: c2)
        ctx.stroke(
            path,
            with: .color(active ? spec.color.opacity(0.6) : Color.white.opacity(0.08)),
            style: StrokeStyle(lineWidth: active ? sc(2) : sc(1), lineCap: .round)
        )

        guard active else { return }

        // ~2 s per traversal; 3 evenly phased dots on the visible mid-path.
        let r = sc(2.5)
        let base = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.0) / 2.0
        for i in 0..<3 {
            let phase = (base + Double(i) / 3.0).truncatingRemainder(dividingBy: 1.0)
            let travel = 0.1 + phase * 0.8
            let u = spec.dir == .toInverter ? travel : (1.0 - travel)
            let pt = cubicPoint(CGFloat(u), s, c1, c2, e)
            let dot = Path(ellipseIn: CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2))
            ctx.drawLayer { layer in
                layer.addFilter(.shadow(color: spec.color.opacity(0.9), radius: sc(3)))
                layer.fill(dot, with: .color(spec.color))
            }
        }
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

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let pulse = connected ? (0.55 + 0.45 * ((sin(t * 2.2) + 1) / 2)) : 1.0
            Circle()
                .fill(connected ? Color.green : Color.red)
                .frame(width: 9 * scale, height: 9 * scale)
                .shadow(color: (connected ? Color.green : Color.red).opacity(pulse), radius: 4 * scale)
                .opacity(connected ? (0.7 + 0.3 * pulse) : 1.0)
        }
    }
}
