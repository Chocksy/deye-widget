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

// MARK: - Pin placement self-test (--pintest)

func runPinTest() -> Int32 {
    MainActor.assumeIsolated {
        print("=== Pin placement self-test ===")
        var pass = true
        // Wokyis: frame (1600,-540 960x540), window 510x300.
        let sf = NSRect(x: 1600, y: -540, width: 960, height: 540)
        let w = NSSize(width: 510, height: 300)
        func check(_ label: String, _ got: NSPoint, _ want: NSPoint) {
            let ok = abs(got.x - want.x) < 0.5 && abs(got.y - want.y) < 0.5
            pass = pass && ok
            print("  \(label.padding(toLength: 26, withPad: " ", startingAt: 0)) got=(\(Int(got.x)),\(Int(got.y))) want=(\(Int(want.x)),\(Int(want.y))) \(ok ? "PASS" : "FAIL")")
        }
        // flush-right centered (relX=1, relY=0.5): x = 1600+450=2050, y = -540+120=-420
        check("flush-right centered", WidgetWindow.desiredOrigin(screenFrame: sf, windowSize: w, relX: 1.0, relY: 0.5), NSPoint(x: 2050, y: -420))
        // flush bottom-left (0,0)
        check("flush bottom-left", WidgetWindow.desiredOrigin(screenFrame: sf, windowSize: w, relX: 0, relY: 0), NSPoint(x: 1600, y: -540))
        // flush top-right (1,1): x=2050, y=-540+240=-300
        check("flush top-right", WidgetWindow.desiredOrigin(screenFrame: sf, windowSize: w, relX: 1, relY: 1), NSPoint(x: 2050, y: -300))
        // out-of-range clamps to [0,1]
        check("clamp rel > 1", WidgetWindow.desiredOrigin(screenFrame: sf, windowSize: w, relX: 5, relY: -2), NSPoint(x: 2050, y: -540))
        // window larger than screen -> origin at screen origin (no negative offset)
        check("oversize window", WidgetWindow.desiredOrigin(screenFrame: sf, windowSize: NSSize(width: 2000, height: 800), relX: 0.5, relY: 0.5), NSPoint(x: 1600, y: -540))
        print(pass ? "ALL PASS" : "FAIL")
        return pass ? 0 : 1
    }
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

// MARK: - Screens CLI (--screens)

/// List attached screens: name, displayID, and frame — used to pick a pin target
/// and to verify placement.
func runScreens() -> Int32 {
    MainActor.assumeIsolated {
        print("=== DeyeWidget --screens ===")
        for s in NSScreen.screens {
            let f = s.frame
            let id = WidgetWindow.displayID(of: s)
            print(String(format: "%-20@ id=%u  frame=(%.0f,%.0f %.0fx%.0f)",
                         s.localizedName as NSString, id, f.origin.x, f.origin.y, f.width, f.height))
        }
        return 0
    }
}

// MARK: - Discovery CLI (--discover)

/// Run one LAN discovery and print the result. Uses sockets: the broadcast path
/// works even while the GUI holds the logger's single TCP socket, but the TCP
/// sweep's V5 probe may fail against a busy logger — quit the GUI for that path.
func runDiscover() -> Int32 {
    let s = MainActor.assumeIsolated { Settings.shared }
    let mac = MainActor.assumeIsolated { s.loggerMAC }
    let serial = MainActor.assumeIsolated { s.loggerSerial }
    let slave = MainActor.assumeIsolated { s.slaveId }
    guard serial != 0 else {
        FileHandle.standardError.write("not configured: set loggerSerial first\n".data(using: .utf8)!)
        return 2
    }
    let subnet = LoggerDiscovery.localSubnetPrefix() ?? "?"
    print("=== DeyeWidget --discover ===")
    print("subnet \(subnet)0/24  serial \(serial)  MAC \(mac)")
    if let r = LoggerDiscovery.discover(loggerMAC: mac, serial: serial, slave: slave) {
        print("FOUND  ip=\(r.ip)  mac=\(r.mac ?? "-")  via \(r.method)")
        return 0
    }
    print("not found")
    return 1
}

// MARK: - History CLI (--history / --gaps), DB-only, no socket

/// Parse a duration like "24h", "5d", "90m", "45s" into seconds. Bare number = seconds.
func parseDuration(_ s: String) -> Int? {
    guard let last = s.last else { return nil }
    let units: [Character: Int] = ["s": 1, "m": 60, "h": 3600, "d": 86_400]
    if let mult = units[last] {
        guard let n = Int(s.dropLast()) else { return nil }
        return n * mult
    }
    return Int(s)   // bare seconds
}

/// ISO8601 in LOCAL time (the user was bitten by a UTC export) e.g. 2026-07-18T14:30:05+03:00.
private let localISO: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = .current
    f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
    return f
}()

func runHistory(_ durArg: String) -> Int32 {
    guard let secs = parseDuration(durArg) else {
        FileHandle.standardError.write("bad duration '\(durArg)' (use e.g. 24h, 5d, 90m)\n".data(using: .utf8)!)
        return 2
    }
    guard let store = HistoryStore(readOnly: true) else { return 1 }
    print("ts,house,mi,pv,battery,grid,soc,grid_v,freq,temp,batt_v")
    for r in store.rows(sinceSecondsAgo: secs) {
        let t = localISO.string(from: Date(timeIntervalSince1970: Double(r.ts)))
        print(String(format: "%@,%.0f,%.0f,%.0f,%.0f,%.0f,%.0f,%.1f,%.2f,%.1f,%.2f",
                     t, r.house, r.mi, r.pv, r.battery, r.grid, r.soc, r.gridV, r.freq, r.temp, r.battV))
    }
    return 0
}

func runGaps(_ durArg: String) -> Int32 {
    guard let secs = parseDuration(durArg) else {
        FileHandle.standardError.write("bad duration '\(durArg)' (use e.g. 24h, 5d, 90m)\n".data(using: .utf8)!)
        return 2
    }
    guard let store = HistoryStore(readOnly: true) else { return 1 }
    let rows = store.rows(sinceSecondsAgo: secs)
    // Rows exist only for successful polls; a jump > 15 s between consecutive
    // timestamps is an outage (logger/grid unreachable) — that's the record.
    let gapFloor = 15
    print("gap_start,gap_end,length")
    var found = 0
    for i in 1..<max(rows.count, 1) {
        let prev = rows[i - 1].ts, cur = rows[i].ts
        let delta = Int(cur - prev)
        if delta > gapFloor {
            found += 1
            let start = localISO.string(from: Date(timeIntervalSince1970: Double(prev)))
            let end = localISO.string(from: Date(timeIntervalSince1970: Double(cur)))
            let mins = delta / 60, rem = delta % 60
            let len = mins > 0 ? "\(mins)m\(rem)s" : "\(rem)s"
            print("\(start),\(end),\(len)")
        }
    }
    FileHandle.standardError.write("\(found) gap(s) > \(gapFloor)s in \(rows.count) samples\n".data(using: .utf8)!)
    return 0
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
if CommandLine.arguments.contains("--pintest") {
    exit(runPinTest())
}
if CommandLine.arguments.contains("--dump") {
    exit(runDump())
}
if CommandLine.arguments.contains("--discover") {
    exit(runDiscover())
}
if CommandLine.arguments.contains("--screens") {
    exit(runScreens())
}
if let i = CommandLine.arguments.firstIndex(of: "--history") {
    exit(runHistory(CommandLine.arguments.count > i + 1 ? CommandLine.arguments[i + 1] : "60m"))
}
if let i = CommandLine.arguments.firstIndex(of: "--gaps") {
    exit(runGaps(CommandLine.arguments.count > i + 1 ? CommandLine.arguments[i + 1] : "1h"))
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)  // no Dock icon
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
