import AppKit
import SwiftUI

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
        statusBar.onConfigChange = { [weak window] in window?.applyConfig() }

        poller.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

// MARK: - Entry point

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
