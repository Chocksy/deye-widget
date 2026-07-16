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

    private let maxHistory = 720

    private let engine: PollEngine
    private var task: Task<Void, Never>?
    private let settings: Settings

    init(settings: Settings) {
        self.settings = settings
        self.engine = PollEngine()
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
            appendHistory(d)
        case .failure(let err):
            self.connected = false
            self.lastError = String(describing: err)
        }
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
