import Foundation
import Combine

/// Decoded snapshot of the inverter state plus derived power flows.
struct InverterData: Equatable {
    // Instantaneous power (W) and battery state.
    var batteryVoltage: Double = 0      // V
    var soc: Int = 0                    // %
    var batteryPower: Int = 0           // W  (+discharge, -charge)
    var batteryCurrent: Double = 0      // A
    var pv1: Int = 0                    // W
    var pv2: Int = 0                    // W
    var miPower: Int = 0               // W  Huawei AC-coupled PV via Gen/MI port
    var gridPower: Int = 0             // W  (+import, -export)
    var gridCTPower: Int = 0           // W
    var loadPower: Int = 0             // W
    var gridVoltage: Double = 0        // V
    var gridFrequency: Double = 0      // Hz
    var inverterTemp: Double = 0       // °C

    // Today's energy totals (kWh).
    var dayBatteryCharge: Double = 0
    var dayBatteryDischarge: Double = 0
    var dayGridImport: Double = 0
    var dayGridExport: Double = 0
    var dayLoad: Double = 0
    var dayPV: Double = 0

    // Derived helpers.
    var pvTotal: Int { pv1 + pv2 }
    /// Total solar seen by the house = DC strings + AC-coupled Huawei.
    var solarTotal: Int { pvTotal + miPower }

    var batteryCharging: Bool { batteryPower < -20 }
    var batteryDischarging: Bool { batteryPower > 20 }
    var gridImporting: Bool { gridPower > 20 }
    var gridExporting: Bool { gridPower < -20 }
}

/// Decode raw holding-register blocks into an `InverterData`.
///
/// - `blockA`: registers 60..109 (index = reg - 60)
/// - `blockB`: registers 150..199 (index = reg - 150)
enum InverterDecoder {
    static func s16(_ v: UInt16) -> Int {
        v >= 0x8000 ? Int(v) - 0x10000 : Int(v)
    }

    static func decode(blockA: [UInt16], blockB: [UInt16]) -> InverterData {
        var d = InverterData()

        func a(_ reg: Int) -> UInt16 {
            let idx = reg - 60
            return (idx >= 0 && idx < blockA.count) ? blockA[idx] : 0
        }
        func b(_ reg: Int) -> UInt16 {
            let idx = reg - 150
            return (idx >= 0 && idx < blockB.count) ? blockB[idx] : 0
        }

        d.batteryVoltage = Double(b(183)) / 100.0
        d.soc = Int(b(184))
        d.batteryPower = s16(b(190))
        d.batteryCurrent = Double(s16(b(191))) / 100.0
        d.pv1 = Int(b(186))
        d.pv2 = Int(b(187))
        d.miPower = s16(b(166))
        d.gridPower = s16(b(169))
        d.gridCTPower = s16(b(172))
        d.loadPower = s16(b(178))
        d.gridVoltage = Double(b(150)) / 10.0
        d.gridFrequency = Double(a(79)) / 100.0   // grid frequency, reg 79 (60-109 block)
        d.inverterTemp = (Double(b(182)) - 1000.0) / 10.0

        d.dayBatteryCharge = Double(a(70)) / 10.0
        d.dayBatteryDischarge = Double(a(71)) / 10.0
        d.dayGridImport = Double(a(76)) / 10.0
        d.dayGridExport = Double(a(77)) / 10.0
        d.dayLoad = Double(a(84)) / 10.0
        d.dayPV = Double(a(108)) / 10.0

        return d
    }
}

/// Owns the client + polling loop and publishes the latest snapshot to the UI.
///
/// All blocking socket IO runs on a dedicated serial queue (`ioQueue`); the
/// `SolarmanClient` is only ever touched from that queue. Published state is
/// updated back on the main actor.
/// The six dashboard nodes (fixed order within their columns).
enum NodeKind: String, CaseIterable {
    case pv, mi, grid, battery, house, ev
}

/// Decides which column the Battery card lives in, with anti-ping-pong
/// hysteresis: migrate to the right (consumers) only after 6 consecutive polls
/// of charging at >= 100 W; back to the left after 6 consecutive polls of
/// discharging at >= 100 W. Below the 100 W floor it holds position.
struct BatteryMigration {
    private(set) var onRight = false
    private var chargeStreak = 0      // battery charging  (power <= -100)
    private var dischargeStreak = 0   // battery discharging (power >= +100)

    static let threshold = 100        // W floor
    static let streak = 6             // consecutive polls (~30 s at 5 s)

    mutating func update(batteryPower: Int) {   // + discharge, - charge
        if batteryPower <= -BatteryMigration.threshold {
            chargeStreak += 1; dischargeStreak = 0
        } else if batteryPower >= BatteryMigration.threshold {
            dischargeStreak += 1; chargeStreak = 0
        } else {
            chargeStreak = 0; dischargeStreak = 0   // below floor: hold
        }
        if chargeStreak >= BatteryMigration.streak { onRight = true }
        if dischargeStreak >= BatteryMigration.streak { onRight = false }
    }
}

/// One point of rolling power history for the chart pane.
struct PowerSample: Identifiable {
    let id = UUID()
    let time: Date
    let house: Double     // W
    let mi: Double        // W
    let battery: Double   // W, signed (+discharge, -charge)
    let grid: Double      // W, signed (+import, -export)
    let soc: Double       // %
}

@MainActor
final class DataPoller: ObservableObject {
    @Published var data = InverterData()
    @Published var connected = false
    @Published var lastUpdate: Date? = nil
    @Published var lastError: String? = nil
    @Published var notConfigured = false
    /// Rolling in-memory power history (~60 min at 5 s = 720 samples).
    /// Resets on app restart — not persisted.
    @Published var history: [PowerSample] = []
    /// Which nodes are currently "active" for the Dashboard tiers, tracked with
    /// hysteresis (promote at |W| >= 50, demote at < 20) so tiers don't flap.
    @Published var activeNodes: Set<NodeKind> = []
    /// Whether the Battery card currently belongs in the right (consumers)
    /// column — true while consistently charging (see BatteryMigration).
    @Published var batteryOnRight = false

    private var migration = BatteryMigration()
    private let maxHistory = 720

    // Auto-rediscovery: after this many consecutive failed polls (~60s at 5s)
    // the logger is presumed to have moved; kick off a LAN discovery, but no more
    // often than `discoveryBackoff` seconds apart (60s first, then 5 min).
    private let failuresBeforeDiscovery = 12
    private var consecutiveFailures = 0
    private var lastDiscoveryAttempt: Date?
    private var discoveryBackoff: TimeInterval = 60
    private var discovering = false
    private let discoveryQueue = DispatchQueue(label: "com.deyewidget.discovery")

    private let engine: PollEngine
    private var task: Task<Void, Never>?
    private let settings: Settings
    private let store: HistoryStore?
    private var pruneTimer: Timer?

    init(settings: Settings) {
        self.settings = settings
        self.engine = PollEngine()
        self.store = HistoryStore()
        // Seed the in-memory chart from disk so the Power Profile pane is full
        // immediately after a relaunch instead of drawing from an empty buffer.
        if let seed = store?.recentSamples(minutes: 60), !seed.isEmpty {
            history = Array(seed.suffix(maxHistory))
        }
        // Prune the rolling window once now (HistoryStore did it at open too) and
        // hourly thereafter; 5-day retention keeps the DB ~15 MB at most.
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            self?.store?.prune()
        }
    }

    func start() {
        stop()
        task = Task { [weak self] in
            await self?.loop()
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func refreshNow() {
        Task { await pollOnce() }
    }

    private func loop() async {
        while !Task.isCancelled {
            await pollOnce()
            let interval = settings.pollInterval
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    }

    /// Perform one poll cycle off the main actor; publish results back on it.
    func pollOnce() async {
        guard settings.isConfigured else {
            notConfigured = true
            connected = false
            lastError = "not configured"
            return
        }
        notConfigured = false
        let cfg = PollConfig(
            host: settings.host,
            port: settings.port,
            serial: settings.loggerSerial,
            slave: settings.slaveId
        )
        let result = await engine.poll(cfg)
        switch result {
        case .success(let d):
            self.data = d
            self.connected = true
            self.lastUpdate = Date()
            self.lastError = nil
            consecutiveFailures = 0
            appendHistory(d)
            store?.record(d)
            updateTiers(d)
        case .failure(let err):
            self.connected = false
            self.lastError = String(describing: err)
            consecutiveFailures += 1
            maybeRediscover()
        }
    }

    /// Kick off a LAN rediscovery when polling has been failing long enough and
    /// we're past the backoff window. Runs off the poll loop; never blocks it.
    private func maybeRediscover() {
        guard settings.isConfigured, !discovering,
              consecutiveFailures >= failuresBeforeDiscovery else { return }
        if let last = lastDiscoveryAttempt, Date().timeIntervalSince(last) < discoveryBackoff { return }

        discovering = true
        lastDiscoveryAttempt = Date()
        let mac = settings.loggerMAC
        let serial = settings.loggerSerial
        let slave = settings.slaveId
        discoveryQueue.async { [weak self] in
            let result = LoggerDiscovery.discover(loggerMAC: mac, serial: serial, slave: slave)
            Task { @MainActor [weak self] in self?.applyDiscovery(result) }
        }
    }

    private func applyDiscovery(_ r: DiscoveryResult?) {
        discovering = false
        guard let r else {
            discoveryBackoff = 300   // nothing found; back off to 5 min
            FileHandle.standardError.write("[discovery] logger not found; backing off 5 min\n".data(using: .utf8)!)
            return
        }
        FileHandle.standardError.write("[discovery] found logger at \(r.ip) via \(r.method)\n".data(using: .utf8)!)
        if settings.host != r.ip { settings.host = r.ip }
        if let mac = r.mac, !mac.isEmpty { settings.loggerMAC = mac }
        consecutiveFailures = 0
        discoveryBackoff = 60
        refreshNow()   // resume polling immediately against the new host
    }

    private func appendHistory(_ d: InverterData) {
        history.append(PowerSample(
            time: Date(),
            house: Double(d.loadPower),
            mi: Double(d.miPower),
            battery: Double(d.batteryPower),
            grid: Double(d.gridPower),
            soc: Double(d.soc)
        ))
        if history.count > maxHistory {
            history.removeFirst(history.count - maxHistory)
        }
    }

    /// Hysteresis: a node is active above 50 W, idle below 20 W, unchanged in
    /// between. EV has no register yet, so it stays idle.
    private func updateTiers(_ d: InverterData) {
        func update(_ k: NodeKind, _ w: Double) {
            if w >= 50 { activeNodes.insert(k) }
            else if w < 20 { activeNodes.remove(k) }
        }
        update(.pv, Double(d.pvTotal))
        update(.mi, Double(abs(d.miPower)))
        update(.grid, Double(abs(d.gridPower)))
        update(.battery, Double(abs(d.batteryPower)))
        update(.house, Double(d.loadPower))
        activeNodes.remove(.ev)

        migration.update(batteryPower: d.batteryPower)
        if migration.onRight != batteryOnRight { batteryOnRight = migration.onRight }
    }
}

struct PollConfig: Equatable {
    let host: String
    let port: UInt16
    let serial: UInt32
    let slave: UInt8
}

/// Runs blocking Solarman IO on a private serial queue and bridges to async.
final class PollEngine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.deyewidget.io")
    private var client: SolarmanClient?

    func poll(_ cfg: PollConfig) async -> Result<InverterData, Error> {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.performPoll(cfg))
            }
        }
    }

    /// Always called on `queue`; safe to touch `client` here.
    private func performPoll(_ cfg: PollConfig) -> Result<InverterData, Error> {
        let c: SolarmanClient
        if let existing = client, existing.host == cfg.host, existing.port == cfg.port,
           existing.loggerSerial == cfg.serial, existing.slaveId == cfg.slave, existing.isConnected {
            c = existing
        } else {
            client?.close()
            c = SolarmanClient(host: cfg.host, port: cfg.port, loggerSerial: cfg.serial, slaveId: cfg.slave, timeout: 3.0)
            client = c
        }

        do {
            let blockA = try c.readHoldingRegisters(start: 60, quantity: 50)
            let blockB = try c.readHoldingRegisters(start: 150, quantity: 50)
            return .success(InverterDecoder.decode(blockA: blockA, blockB: blockB))
        } catch {
            c.close()
            client = nil
            return .failure(error)
        }
    }
}
