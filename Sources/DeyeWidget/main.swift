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
        // Generic secondary-display fixture (origin offset + non-zero position).
        let sf = NSRect(x: 1440, y: 0, width: 800, height: 600)
        let w = NSSize(width: 400, height: 300)
        func check(_ label: String, _ got: NSPoint, _ want: NSPoint) {
            let ok = abs(got.x - want.x) < 0.5 && abs(got.y - want.y) < 0.5
            pass = pass && ok
            print("  \(label.padding(toLength: 26, withPad: " ", startingAt: 0)) got=(\(Int(got.x)),\(Int(got.y))) want=(\(Int(want.x)),\(Int(want.y))) \(ok ? "PASS" : "FAIL")")
        }
        // flush-right centered (relX=1, relY=0.5): x = 1440+400=1840, y = 0+150=150
        check("flush-right centered", WidgetWindow.desiredOrigin(screenFrame: sf, windowSize: w, relX: 1.0, relY: 0.5), NSPoint(x: 1840, y: 150))
        // flush bottom-left (0,0)
        check("flush bottom-left", WidgetWindow.desiredOrigin(screenFrame: sf, windowSize: w, relX: 0, relY: 0), NSPoint(x: 1440, y: 0))
        // flush top-right (1,1): x=1840, y=0+300=300
        check("flush top-right", WidgetWindow.desiredOrigin(screenFrame: sf, windowSize: w, relX: 1, relY: 1), NSPoint(x: 1840, y: 300))
        // out-of-range clamps to [0,1]
        check("clamp rel > 1", WidgetWindow.desiredOrigin(screenFrame: sf, windowSize: w, relX: 5, relY: -2), NSPoint(x: 1840, y: 0))
        // window larger than screen -> origin at screen origin (no negative offset)
        check("oversize window", WidgetWindow.desiredOrigin(screenFrame: sf, windowSize: NSSize(width: 2000, height: 800), relX: 0.5, relY: 0.5), NSPoint(x: 1440, y: 0))
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

// MARK: - Battery ETA self-test (--etacheck) / live estimate (--eta)

/// Synthetic house: discharges 3 kW 18-24, 600 W 00-06, 1 kW 06-09; solar
/// charges at 3 kW from 09:00 until full. 360 Wh per 1 %, floor 35 %.
private func synthRows(from start: Date, to end: Date, soc startSoc: Double,
                       cal: Calendar) -> (rows: [HistoryStore.Row], floorHits: [Date]) {
    var rows: [HistoryStore.Row] = []
    var hits: [Date] = []
    var soc = startSoc
    var t = start
    while t <= end {
        let h = cal.component(.hour, from: t)
        var b: Double
        if h >= 9 && h < 18 { b = soc < 100 ? -3000 : 0 }
        else { b = h >= 18 ? 3000 : (h < 6 ? 600 : 1000); if soc <= 35 { b = 0 } }
        rows.append(HistoryStore.Row(ts: Int64(t.timeIntervalSince1970), house: max(b, 0), mi: 0, pv: 0,
                                     battery: b, grid: 0, soc: soc.rounded(), gridV: 230, freq: 50,
                                     temp: 30, battV: 52))
        let before = soc
        soc = min(max(soc - b * 30 / 3600 / 360, 35), 100)
        if before > 35 && soc <= 35 { hits.append(t.addingTimeInterval(30)) }
        t = t.addingTimeInterval(30)
    }
    return (rows, hits)
}

func runETACheck() -> Int32 {
    print("=== Battery ETA self-test ===")
    var pass = true
    let cal = Calendar.current
    let hm = { (d: Date?) in d.map { BatteryEstimate.clock.string(from: $0) } ?? "nil" }
    func check(_ label: String, _ ok: Bool, _ detail: String) {
        pass = pass && ok
        print("  \(label.padding(toLength: 30, withPad: " ", startingAt: 0)) \(detail)  \(ok ? "PASS" : "FAIL")")
    }
    func near(_ a: Date?, _ b: Date, _ tol: TimeInterval = 600) -> Bool {
        guard let a else { return false }
        return abs(a.timeIntervalSince(b)) <= tol
    }
    // Fixed June dates keep DST out of the synthetic days.
    let day0 = cal.date(from: DateComponents(year: 2026, month: 6, day: 1, hour: 18))!
    let at = { (dayOffset: Int, hour: Int, minute: Int) -> Date in
        cal.date(bySettingHour: hour, minute: minute, second: 0,
                 of: cal.date(byAdding: .day, value: dayOffset, to: day0)!)!
    }

    // 1. Three nights of history, now = day 3 21:00 (SOC 75). Analytic: 40 % × 360 Wh =
    //    14.4 kWh; 21-24 uses 9.0, 00-06 uses 3.6, then 1 kW for 1.8 h → 07:48.
    let now1 = at(3, 21, 0)
    let s1 = synthRows(from: day0, to: now1, soc: 100, cal: cal)
    let last1 = s1.rows.last!
    let e1 = BatteryEstimate.compute(now: now1, soc: Int(last1.soc), batteryW: Int(last1.battery),
                                     rows: s1.rows, calendar: cal)
    let want1 = at(4, 7, 48), sun1 = at(4, 9, 0)
    if case let .discharging(until, solarAt, learning) = e1 {
        check("discharge until (want \(hm(want1)))", near(until, want1) && !learning,
              "got until=\(hm(until)) learning=\(learning)")
        check("solar start (want \(hm(sun1)))", near(solarAt, sun1), "got \(hm(solarAt))")
    } else { check("discharge case", false, "got \(e1)") }
    let wh = BatteryEstimate.whPerPercent(rows: s1.rows, floor: 35) ?? 0
    check("Wh per % (want 360)", abs(wh - 360) < 20, String(format: "got %.0f", wh))

    // 2. Charging at 3 kW, day 4 10:00. fullBy = now + (100 − soc) × 360 / 3000 h.
    let now2 = at(4, 10, 0)
    let s2 = synthRows(from: day0, to: now2, soc: 100, cal: cal)
    let last2 = s2.rows.last!
    let e2 = BatteryEstimate.compute(now: now2, soc: Int(last2.soc), batteryW: Int(last2.battery),
                                     rows: s2.rows, calendar: cal)
    let want2 = now2.addingTimeInterval((100 - last2.soc) * 360 / 3000 * 3600)
    if case let .charging(fullBy) = e2 {
        check("charging full by (want \(hm(want2)))", near(fullBy, want2), "got \(hm(fullBy))")
    } else { check("charging case", false, "got \(e2)") }

    // 3. Reserve: day 4 08:30, parked at 35 % since the floor hit (~07:48). The
    //    logged SOC is whole %, so it reads 35 from 35.5 % on: 0.5 × 360 Wh at
    //    1 kW = 10.8 min before the true hit.
    let now3 = at(4, 8, 30)
    let s3 = synthRows(from: day0, to: now3, soc: 100, cal: cal)
    let hit3 = s3.floorHits.last!.addingTimeInterval(-0.5 * 360 / 1000 * 3600)
    let e3 = BatteryEstimate.compute(now: now3, soc: 35, batteryW: 0, rows: s3.rows, calendar: cal)
    if case let .reserve(since) = e3 {
        check("reserve since (want \(hm(hit3)))", near(since, hit3), "got \(hm(since))")
    } else { check("reserve case", false, "got \(e3)") }

    // 4. Learning: history starts day 2 12:00 → only 1 night. 1 h mean = 3 kW,
    //    so 14.4 kWh lasts 4.8 h → 01:48, learning = true.
    let s4 = synthRows(from: at(2, 12, 0), to: now1, soc: 100, cal: cal)
    let last4 = s4.rows.last!
    let e4 = BatteryEstimate.compute(now: now1, soc: Int(last4.soc), batteryW: Int(last4.battery),
                                     rows: s4.rows, calendar: cal)
    let want4 = now1.addingTimeInterval((last4.soc - 35) * 360 / 3000 * 3600)
    if case let .discharging(until, _, learning) = e4 {
        check("learning until (want \(hm(want4)))", near(until, want4) && learning,
              "got until=\(hm(until)) learning=\(learning)")
    } else { check("learning case", false, "got \(e4)") }

    // 5. Real-data backtest (print only).
    print("  --- real-data backtest ---")
    if let store = HistoryStore(readOnly: true) {   // nil (and skipped) when no DB
        let all = store.rows(sinceSecondsAgo: 7 * 86_400)
        // Sweep evening/night start points; print predicted vs actual floor hit.
        for day in 19...22 {
            for hr in [18, 20, 21, 22, 23, 24, 26, 28] {
                guard let target = cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hr)) else { continue }
                let tTs = Int64(target.timeIntervalSince1970)
                let past = all.filter { $0.ts <= tTs && $0.ts >= tTs - 4 * 86_400 }
                guard let cur = past.last, tTs - cur.ts < 120, cur.battery > 100, cur.soc > 36 else { continue }
                let e = BatteryEstimate.compute(now: target, soc: Int(cur.soc), batteryW: Int(cur.battery), rows: past)
                guard let actual = all.first(where: { $0.ts > tTs && $0.soc <= 35 })
                        .map({ Date(timeIntervalSince1970: Double($0.ts)) }),
                      actual.timeIntervalSince(target) < 16 * 3600 else { continue }
                var pred = "\(e)", err = ""
                if case let .discharging(until, solarAt, _) = e {
                    pred = "until=\(hm(until)) solar=\(hm(solarAt))"
                    if let u = until { err = String(format: "%+.0f min", u.timeIntervalSince(actual) / 60) }
                }
                print(String(format: "  %@  SOC %2.0f  %@  actual %@  %@",
                             DateFormatter.localizedString(from: target, dateStyle: .short, timeStyle: .short),
                             cur.soc, pred, hm(actual), err))
            }
        }
    } else {
        print("  history DB not found; skipped")
    }

    print(pass ? "ALL PASS" : "FAIL")
    return pass ? 0 : 1
}

func runETA() -> Int32 {
    guard let store = HistoryStore(readOnly: true) else { return 1 }
    let t0 = Date()
    let rows = store.rows(sinceSecondsAgo: 4 * 86_400)
    guard let cur = rows.last else { print("no rows"); return 1 }
    let floor = MainActor.assumeIsolated { Settings.shared.batteryFloor }
    let e = BatteryEstimate.compute(now: Date(), soc: Int(cur.soc), batteryW: Int(cur.battery),
                                    rows: rows, floor: floor)
    let ms = Date().timeIntervalSince(t0) * 1000
    let wh = BatteryEstimate.whPerPercent(rows: rows, floor: floor) ?? 0
    let hm = { (d: Date?) in d.map { BatteryEstimate.clock.string(from: $0) } ?? "nil" }
    var desc = "\(e)"
    switch e {
    case let .discharging(until, solarAt, learning):
        desc = "discharging until=\(hm(until)) solarAt=\(hm(solarAt)) learning=\(learning)"
    case let .charging(fullBy): desc = "charging fullBy=\(hm(fullBy))"
    case let .reserve(since): desc = "reserve since=\(hm(since))"
    case .none: desc = "none"
    }
    print(String(format: "SOC %.0f%% batt %.0f W  %.0f Wh/%%  floor %.0f  → %@  (%d rows, %.0f ms)",
                 cur.soc, cur.battery, wh, floor, desc, rows.count, ms))
    return 0
}

// MARK: - ETA visual check (--etashots DIR), offscreen ImageRenderer only

func runETAShots(_ dir: String) -> Int32 {
    MainActor.assumeIsolated {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let settings = Settings.shared
        let poller = DataPoller(settings: settings, store: nil)   // never touches the DB
        FlowView.offscreen = true
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let t = { (h: Int, m: Int, addDay: Int) in
            today.addingTimeInterval(Double(addDay * 86_400 + h * 3600 + m * 60))
        }
        struct Shot {
            let name: String; let soc: Int; let batt: Int; let pv: Int; let mi: Int; let grid: Int
            let house: Int; let onRight: Bool; let eta: BatteryETA
        }
        let shots: [Shot] = [
            Shot(name: "discharge-before-solar", soc: 73, batt: 3000, pv: 0, mi: 0, grid: 0, house: 3050,
                 onRight: false, eta: .discharging(until: t(7, 37, 1), solarAt: t(9, 0, 1), learning: false)),
            Shot(name: "discharge-active-tier", soc: 60, batt: 1200, pv: 0, mi: 0, grid: 3800, house: 5000,
                 onRight: false, eta: .discharging(until: t(7, 37, 1), solarAt: t(9, 0, 1), learning: false)),
            Shot(name: "lasts-until-solar", soc: 88, batt: 650, pv: 0, mi: 0, grid: 0, house: 680,
                 onRight: false, eta: .discharging(until: nil, solarAt: t(9, 0, 1), learning: false)),
            Shot(name: "learning", soc: 56, batt: 700, pv: 0, mi: 0, grid: 0, house: 720,
                 onRight: false, eta: .discharging(until: t(5, 30, 1), solarAt: t(9, 0, 1), learning: true)),
            Shot(name: "charging-active-tier", soc: 84, batt: -2500, pv: 6500, mi: 1200, grid: -3700, house: 1500,
                 onRight: true, eta: .charging(fullBy: t(13, 10, 0))),
            Shot(name: "charging-hero", soc: 84, batt: -6500, pv: 7200, mi: 800, grid: 0, house: 1500,
                 onRight: true, eta: .charging(fullBy: t(13, 10, 0))),
            Shot(name: "reserve", soc: 35, batt: 0, pv: 0, mi: 0, grid: 1200, house: 1200,
                 onRight: false, eta: .reserve(since: t(7, 21, 0))),
            Shot(name: "none", soc: 99, batt: -150, pv: 2000, mi: 0, grid: -950, house: 900,
                 onRight: true, eta: .none),
        ]
        for shot in shots {
            var d = InverterData()
            d.soc = shot.soc; d.batteryPower = shot.batt; d.batteryVoltage = 53.1
            d.pv1 = shot.pv; d.miPower = shot.mi; d.gridPower = shot.grid; d.loadPower = shot.house
            d.gridVoltage = 233; d.gridFrequency = 50; d.inverterTemp = 31
            d.dayPV = 12.3; d.dayLoad = 14.2; d.dayBatteryCharge = 9.1; d.dayBatteryDischarge = 8.4
            poller.data = d
            poller.connected = true
            poller.lastUpdate = Date()
            poller.batteryOnRight = shot.onRight
            poller.batteryETA = shot.eta
            var act: Set<NodeKind> = []
            if shot.pv >= 50 { act.insert(.pv) }
            if abs(shot.mi) >= 50 { act.insert(.mi) }
            if abs(shot.grid) >= 50 { act.insert(.grid) }
            if abs(shot.batt) >= 50 { act.insert(.battery) }
            if shot.house >= 50 { act.insert(.house) }
            poller.activeNodes = act
            for mode in [DisplayMode.dashboard, .flow] {
                for scale in [CGFloat(0.72), 1.0] {
                    let view = FlowView(poller: poller, settings: settings, displayMode: mode, scale: scale)
                        .background(Color(white: 0.16))
                        .environment(\.colorScheme, .dark)
                    let r = ImageRenderer(content: view)
                    r.scale = 2
                    let path = "\(dir)/\(mode.rawValue)-\(shot.name)-\(scale == 1 ? "1.00" : "0.72").png"
                    guard let tiff = r.nsImage?.tiffRepresentation,
                          let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
                        print("render failed: \(path)"); return 1
                    }
                    try? png.write(to: URL(fileURLWithPath: path))
                    print(path)
                }
            }
        }
        return 0
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
if CommandLine.arguments.contains("--pintest") {
    exit(runPinTest())
}
if CommandLine.arguments.contains("--etacheck") {
    exit(runETACheck())
}
if CommandLine.arguments.contains("--eta") {
    exit(runETA())
}
if let i = CommandLine.arguments.firstIndex(of: "--etashots") {
    exit(runETAShots(CommandLine.arguments.count > i + 1 ? CommandLine.arguments[i + 1] : "/tmp/eta-shots"))
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
