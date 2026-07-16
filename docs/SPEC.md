# DeyeWidget — live desktop energy-flow widget for macOS

## Goal

A single native macOS app (SwiftUI, Swift Package Manager, no Xcode project, no signing beyond local ad-hoc) that shows a LIVE DeyeCloud-style power-flow graph in a borderless "widget" window sitting on the desktop, plus a menu bar item with battery SOC. Data comes directly from the Deye inverter's Solarman LSW-5 logger on the LAN via Solarman V5 protocol over TCP — no cloud, no Python.

Why not a true WidgetKit widget: WidgetKit timelines refresh every ~5–15 min at best — useless for "live". A desktop-level borderless window IS the widget, and can poll every 5 s.

## Target system (verified live on 2026-07-16)

- Logger: LSW-5 at `<LOGGER_IP>` (e.g. `192.168.1.100`), TCP port `8899`, logger serial `<LOGGER_SERIAL>`, Modbus slave id `1`
- Inverter: Deye 8 kW single-phase LP1 hybrid (device type reg 0 = 3), SN `<INVERTER_SN>`
- Register map = Sunsynk/Deye single-phase LP1. All values verified against DeyeCloud:

| Register | Meaning | Scale/type |
|---|---|---|
| 183 | Battery voltage | u16 /100 → V |
| 184 | Battery SOC | u16 → % |
| 190 | Battery power | s16 → W (+discharge, −charge) |
| 191 | Battery current | s16 /100 → A |
| 186, 187 | PV1, PV2 power (DC strings, currently 0 — panels not yet connected) | u16 → W |
| 166 | Gen/MI port power = Huawei 6 kW AC-coupled PV (verified: 168 W vs DeyeCloud "MI 193 W") | s16 → W |
| 169 | Grid total power | s16 → W (+import, −export) |
| 172 | Grid CT (external) power | s16 → W |
| 178 | Load (UPS/house) power | s16 → W |
| 150 | Grid voltage L1 | u16 /10 → V |
| 182 | Inverter temp | (u16 −1000)/10 → °C |
| 70 | Day battery charge | u16 /10 → kWh |
| 71 | Day battery discharge | u16 /10 → kWh |
| 76 | Day grid import | u16 /10 → kWh |
| 77 | Day grid export | u16 /10 → kWh |
| 84 | Day load energy | u16 /10 → kWh |
| 108 | Day PV energy | u16 /10 → kWh |

Poll = two reads per cycle: holding regs 60–109 (50) and 150–199 (50), every 5 s.

## Solarman V5 protocol (implement in Swift, TCP socket)

Request frame wrapping a Modbus RTU "read holding registers" (func 0x03):

```
A5 <len:u16 LE> <control:u16 LE = 0x4510> <serial#:u16 LE seq> <loggerSerial:u32 LE>
<payload> <checksum:u8> 15
```

- payload = `frameType(0x02) sensorType(0x0000) deliveryTime(u32=0) powerOnTime(u32=0) offsetTime(u32=0) + modbusRTUframe`
- len = payload length
- checksum = sum of all bytes between (not including) A5 and checksum, & 0xFF
- Modbus RTU frame: `slave(01) func(03) startReg(u16 BE) count(u16 BE) crc16(u16 LE, modbus poly 0xA001)`
- Response: same framing, control 0x1510; modbus RTU answer starts at payload offset 14 (`frameType(1) status(1) totalTime(4) powerOnTime(4) offsetTime(4)` = 14 bytes); verify V5 checksum + modbus CRC; registers are u16 BE in the RTU data.

Reference implementation to mirror byte-for-byte: the Python [`pysolarmanv5`](https://github.com/jmccrohan/pysolarmanv5) library (`pip install pysolarmanv5`). If any framing doubt arises, cross-check against it (example call in Verification below).

The sequential serial# field: echo any u16, increment per request. One TCP connection reused across polls; reconnect on error/timeout (3 s timeout). Requests are strictly sequential (send → read full response → next).

## App structure

```
deye-widget/
  Package.swift            # swift-tools 5.9+, macOS 13+, executable target "DeyeWidget"
  Sources/DeyeWidget/
    main.swift             # NSApplication bootstrap (accessory activation policy — no Dock icon)
    SolarmanClient.swift   # V5 framing + modbus + polling loop (async, Timer/Task)
    InverterData.swift     # decoded model struct + derived flows
    FlowView.swift         # SwiftUI flow graph
    WidgetWindow.swift     # borderless desktop-level NSWindow + NSHostingView
    StatusBar.swift        # NSStatusItem: "☀︎ 96%" style, menu: Refresh, Settings…, Quit
    Settings.swift         # UserDefaults-backed: host, port, logger serial, poll interval; tiny SwiftUI form in a normal window
  docs/SPEC.md
```

### Window behavior
- Borderless (`.borderless`), non-activating, `level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)))` so it floats above the wallpaper/icons but stays under normal app windows (widget feel). `collectionBehavior = [.canJoinAllSpaces, .stationary]`.
- Draggable anywhere (`isMovableByWindowBackground = true`), frame autosaved (`setFrameAutosaveName`).
- Background: rounded 24 pt corners, `NSVisualEffectView`/`.ultraThinMaterial` dark translucency.
- Size ≈ 420×360.

### Flow graph (FlowView) — replicate DeyeCloud layout, but nicer
Six nodes around a center inverter node, connected by rounded-orthogonal dashed paths:

```
 PV(DC strings)     MI (Huawei PV)      Grid
      ┌──────────┐      │        ┌────────────┐
      └────────► INVERTER ◄──────┘  (arrows follow actual direction)
      ┌──────────►    │   ◄──────┐
 Battery(SOC%)     House(UPS)      EV/Aux (future)
```

- Node = SF Symbol in a rounded-rect card + watts label underneath (`sun.max`, `solarpanel` (MI), `bolt.horizontal` / power-pylon-ish for grid, `battery.75` dynamic by SOC, `house`, `car` for EV placeholder).
- Battery node also shows SOC % prominently and charge/discharge direction.
- Active flow (|W| > 20): the dashed connector animates (marching dashes via `strokeStyle` `dashPhase` driven by `TimelineView`), arrowhead pointing in the true direction (grid import vs export, battery charge vs discharge). Inactive flow: static, 25 % opacity, node dimmed.
- Color coding: PV/MI green, grid import red / export teal, battery discharge orange / charge green, load blue. Subtle — dark background, thin 1.5 pt lines.
- Bottom strip: today's kWh — PV, charge/discharge, import/export, load — small monospaced digits. Plus grid voltage + inverter temp, tiny.
- EV node shows "—" until nonzero (placeholder for future car charger; reads same load registers, no dedicated register yet — just render 0/dash).
- Header row: "Deye 8kW" + last-update time + green/red connection dot. On poll failure show last data grayed with red dot; never blank the widget.

### Menu bar
`NSStatusItem` title like `⚡96%` (SOC, updates each poll; show `--` when disconnected). Menu: current snapshot lines (Load / PV+MI / Grid / Battery W), Settings…, Quit.

## Hard constraints
- Pure Swift + Apple frameworks only (Foundation, Network or BSD sockets, AppKit, SwiftUI). NO third-party packages.
- No cloud calls, LAN only. Never write to inverter registers — function code 0x03 reads ONLY.
- Don't touch anything outside `/Volumes/External/Development/deye-widget/`.
- No git init/commits.
- Defaults: host empty, port 8899, serial 0, slave 1, 5 s poll — the user supplies host `<LOGGER_IP>` + serial `<LOGGER_SERIAL>` via Settings (until then the widget stays idle).

## Verification (mandatory, run all)
1. `cd /Volumes/External/Development/deye-widget && swift build -c release` — zero errors.
2. Protocol unit check (no GUI): add a tiny `--dump` CLI mode to main.swift: `.build/release/DeyeWidget --dump` connects, polls once, prints all mapped values as text, exits 0. Run it; SOC must be 0–100, battery voltage 45–58 V, load 0–10000 W.
3. Cross-check against the Python reference (values within a few W/1 % — readings are seconds apart), using [pysolarmanv5](https://github.com/jmccrohan/pysolarmanv5):
   `python3 -c "from pysolarmanv5 import PySolarmanV5; m=PySolarmanV5('<LOGGER_IP>',<LOGGER_SERIAL>,port=8899,mb_slave_id=1,socket_timeout=10); r=m.read_holding_registers(150,50); print('SOC',r[34],'battV',r[33]/100,'load',r[28],'MI',r[16])"`
4. Launch the app (`.build/release/DeyeWidget &`), confirm it stays running 30 s (poll loop alive, no crash), then screenshot: `screencapture -x /tmp/deye-widget.png` and report. Leave the app running.
5. Report: files created, verification output verbatim, any deviation from spec (expected: none).
