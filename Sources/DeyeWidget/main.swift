import AppKit
import SwiftUI

// MARK: - Battery migration self-test (--migrationcheck)

func runMigrationCheck() -> Int32 {
    func run(_ label: String, _ powers: [Int]) -> Bool {
        var m = BatteryMigration()
        for p in powers { m.update(batteryPower: p) }
        print("  \(label): onRight=\(m.onRight)")
        return m.onRight
    }
    print("=== BatteryMigration self-test ===")
    // + = discharge, - = charge. Threshold 100 W, streak 6.
    let charge6 = run("charge -500W x6 -> RIGHT", Array(repeating: -500, count: 6)) == true
    let discharge6 = run("discharge +500W x6 -> LEFT", Array(repeating: 500, count: 6)) == false
    let small = run("+/-50W x10 -> no move (LEFT)", (0..<10).map { $0.isMultiple(of: 2) ? 50 : -50 }) == false
    let charge5 = run("charge -500W x5 (below streak) -> LEFT", Array(repeating: -500, count: 5)) == false
    // charge to right, then a single small blip must NOT flip it back
    var held = BatteryMigration()
    for _ in 0..<6 { held.update(batteryPower: -500) }
    held.update(batteryPower: 30)   // below floor
    let sticky = held.onRight == true
    print("  charge x6 then +30W blip -> stays RIGHT: \(sticky)")
    let ok = charge6 && discharge6 && small && charge5 && sticky
    print(ok ? "ALL PASS" : "FAIL")
    return ok ? 0 : 1
}

// MARK: - Menu mapping self-test (--menucheck)

func runMenuCheck() -> Int32 {
    MainActor.assumeIsolated {
        print("=== Menu item mapping self-test ===")
        var pass = true
        func check(_ label: String, _ got: String, _ want: String) {
            let ok = got == want
            pass = pass && ok
            let padLabel = label.padding(toLength: 22, withPad: " ", startingAt: 0)
            print("  \(padLabel) got=\(got.padding(toLength: 10, withPad: " ", startingAt: 0)) want=\(want.padding(toLength: 10, withPad: " ", startingAt: 0)) \(ok ? "PASS" : "FAIL")")
        }
        let s = Settings.shared
        // Drive each Size item's handler effect and assert the resulting setting.
        for preset in SizePreset.allCases {
            let item = NSMenuItem()
            item.representedObject = preset.rawValue          // exactly as buildMenu sets it
            if let p = StatusBarController.size(from: item) { s.scale = Double(p.scale) }
            let want = preset == .small ? 0.72 : (preset == .medium ? 1.0 : 1.15)
            check("Size→\(preset.title)", String(format: "%.2f", s.scale), String(format: "%.2f", want))
        }
        // Drive each Display item's handler effect and assert the resulting setting.
        for mode in DisplayMode.allCases {
            let item = NSMenuItem()
            item.representedObject = mode.rawValue
            if let m = StatusBarController.display(from: item) { s.displayMode = m }
            check("Display→\(mode.title)", s.displayMode.rawValue, mode.rawValue)
        }
        // @Published delivery timing — the actual bug. The publisher emits in
        // willSet, so reading the property back is stale; the delivered value is
        // correct. Prove the delivered value (what WidgetWindow now uses) is new.
        s.scale = 1.15
        var delivered = -1.0
        var readBack = -1.0
        let c = s.$scale.dropFirst().sink { newVal in delivered = newVal; readBack = s.scale }
        s.scale = 0.72
        _ = c
        print("  --- @Published delivery (scale 1.15 → 0.72) ---")
        check("delivered value", String(format: "%.2f", delivered), "0.72")
        print(String(format: "  read-back inside sink = %.2f (stale willSet value — the old bug)", readBack))
        print(pass ? "ALL PASS" : "FAIL")
        return pass ? 0 : 1
    }
}

// MARK: - CLI dump mode (no GUI)

func runDump() -> Int32 {
    let settings = MainActor.assumeIsolated { Settings.shared }
    let host = MainActor.assumeIsolated { settings.host }
    let port = MainActor.assumeIsolated { settings.port }
    let serial = MainActor.assumeIsolated { settings.loggerSerial }
    let slave = MainActor.assumeIsolated { settings.slaveId }

    guard MainActor.assumeIsolated({ settings.isConfigured }) else {
        FileHandle.standardError.write(
            "not configured: set host + logger serial (e.g. `defaults write DeyeWidget host 192.168.1.100; defaults write DeyeWidget loggerSerial 1234567890`) or use Settings…\n".data(using: .utf8)!)
        return 2
    }

    let client = SolarmanClient(host: host, port: port, loggerSerial: serial, slaveId: slave, timeout: 5.0)
    do {
        let blockA = try client.readHoldingRegisters(start: 60, quantity: 50)
        let blockB = try client.readHoldingRegisters(start: 150, quantity: 50)
        let d = InverterDecoder.decode(blockA: blockA, blockB: blockB)
        client.close()

        print("=== DeyeWidget --dump ===")
        print("host \(host):\(port)  serial \(serial)  slave \(slave)")
        print("")
        print(String(format: "SOC                 %d %%", d.soc))
        print(String(format: "Battery voltage     %.2f V", d.batteryVoltage))
        print(String(format: "Battery power       %d W (%@)", d.batteryPower,
                     d.batteryCharging ? "charging" : (d.batteryDischarging ? "discharging" : "idle")))
        print(String(format: "Battery current     %.2f A", d.batteryCurrent))
        print(String(format: "PV1 / PV2           %d / %d W", d.pv1, d.pv2))
        print(String(format: "MI (Huawei PV)      %d W", d.miPower))
        print(String(format: "Grid total          %d W (%@)", d.gridPower,
                     d.gridImporting ? "import" : (d.gridExporting ? "export" : "idle")))
        print(String(format: "Grid CT             %d W", d.gridCTPower))
        print(String(format: "Load                %d W", d.loadPower))
        print(String(format: "Grid voltage        %.1f V", d.gridVoltage))
        print(String(format: "Grid frequency      %.2f Hz", d.gridFrequency))
        print(String(format: "Inverter temp       %.1f °C", d.inverterTemp))
        print("")
        print(String(format: "Day PV              %.1f kWh", d.dayPV))
        print(String(format: "Day batt charge     %.1f kWh", d.dayBatteryCharge))
        print(String(format: "Day batt discharge  %.1f kWh", d.dayBatteryDischarge))
        print(String(format: "Day grid import     %.1f kWh", d.dayGridImport))
        print(String(format: "Day grid export     %.1f kWh", d.dayGridExport))
        print(String(format: "Day load            %.1f kWh", d.dayLoad))
        return 0
    } catch {
        client.close()
        FileHandle.standardError.write("dump failed: \(error)\n".data(using: .utf8)!)
        return 1
    }
}

// MARK: - App delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var poller: DataPoller!
    private var window: WidgetWindow!
    private var statusBar: StatusBarController!
    private var activity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // As an LSUIElement accessory whose only window sits at desktop level,
        // the app is a prime App Nap target — which would throttle/suspend the
        // 5 s poll loop and drop the logger socket. Opt out (but still allow the
        // Mac to sleep normally) so polling stays live.
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Live inverter polling")

        let settings = Settings.shared
        poller = DataPoller(settings: settings)

        window = WidgetWindow(poller: poller, settings: settings)
        window.orderFrontRegardless()

        statusBar = StatusBarController(poller: poller, settings: settings)

        poller.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

// MARK: - Entry point

if CommandLine.arguments.contains("--migrationcheck") {
    exit(runMigrationCheck())
}
if CommandLine.arguments.contains("--menucheck") {
    exit(runMenuCheck())
}
if CommandLine.arguments.contains("--dump") {
    exit(runDump())
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)  // no Dock icon
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
