# DeyeWidget design pass — "Apple-grade" brief

The functional v1 works. This pass is visual only — no changes to SolarmanClient, polling, or data model. Target: the widget should look like Apple shipped it — think Tesla app power flow × macOS Sonoma widget aesthetic.

## Overall
- Window stays 420×360-ish (up to 440×400 allowed). Rounded 28 pt continuous-corner card.
- Background: real vibrancy — `NSVisualEffectView` (`.hudWindow` or `.underWindowBackground`, state `.active`) under the SwiftUI content, plus a subtle top-to-bottom dark gradient overlay (black 20%→45%) so content pops on any wallpaper. No flat gray fills anywhere.
- Adapt to light/dark automatically (use semantic colors + material; test dark).
- Typography: SF Pro Rounded (`.rounded` design) throughout. All numerals `.monospacedDigit()`. Watts values formatted: `1.24 kW` when ≥1000, else `283 W`.

## Flow graph — Tesla-app style, not boxes
Kill the rounded-rect cards. Each node becomes:
- A 44–52 pt circle with an ultraThin material fill, 1 pt white 15% stroke, soft shadow, containing a hierarchical-rendered SF Symbol tinted with the node color.
- Label under the circle: name in 10 pt secondary, value in 13 pt semibold rounded.
- Node glows (soft colored shadow, radius 8) only when active.

Connections: smooth cubic Bézier curves from node circle edge to the central inverter node (not orthogonal elbows). On active flows, animate 2–3 small bright dots (3 pt circles with glow) traveling along the path in the true power direction (TimelineView-driven, ~2 s per traversal, evenly phased). Inactive: hairline 1 pt white 8% curve, no dots. Remove arrowheads — the moving dots ARE the direction cue.

Center node: slightly larger circle, `bolt.fill` or inverter glyph, subtle breathing animation (scale 1.0→1.03) when any flow is active.

Node palette (single accent per node, used for symbol tint, glow, and dots):
- PV strings: `sun.max.fill`, yellow-green (#A8D93A-ish, use Color(hue:...) or asset-free literal)
- MI/Huawei: `solarpanel` — wait, use `sun.horizon.fill` or `rays` if solarpanel unavailable — green
- Grid: `bolt.horizontal.fill` or `powerplug.fill`; teal when exporting, red-orange when importing, gray idle
- Battery: SF battery symbol matching SOC (`battery.100`, `.75`, `.50`, `.25`) — green when charging, orange when discharging; SOC % is the node's primary label (17 pt bold), watts secondary
- House: `house.fill`, blue
- EV: `car.fill` (or `bolt.car.fill`), purple; 30% opacity + "—" until nonzero

## Header
Left: small yellow `bolt.fill` in a tiny gradient circle + "Deye 8 kW" 15 pt semibold rounded. Right: relative "updated 3 s ago" in 10 pt secondary + status dot (green breathing / red). Drop the raw clock.

## Stats strip (bottom)
Replace the cramped colored text rows with a single horizontal row of 4 stat capsules (ultraThin material, 8 pt radius):
`☀️ 0.0` (PV today) · `🔋 +25.3/−1.9` (charge/discharge, use SF symbols not emoji) · `⚡ ↓4.9 ↑9.1` (import/export) · `🏠 14.3` (load today)
Each capsule: 9 pt caption label on top (PV · BATT · GRID · HOME), 12 pt semibold value. kWh implied, noted once at row edge in 8 pt tertiary.
Below or merged: one 9 pt tertiary line `223.6 V · 32.0 °C · 53.21 V batt`.

## Micro-details
- All layout changes animate with `.animation(.spring(duration: 0.6), value:)` on data updates (numbers can snap; positions/opacity spring).
- Values changing should use `.contentTransition(.numericText())`.
- No text truncation at any plausible value width (test 6 kW values).
- Menu bar item: swap title to SF symbol `bolt.fill` + SOC, e.g. "⚡︎ 95 %" using attributed string with the symbol, not the emoji.

## Verification
1. `swift build -c release` clean; relaunch (kill old PID first).
2. Capture window-only screenshot: find window via CGWindowList (owner "DeyeWidget"), `screencapture -x -l <id> /tmp/deye-v2.png`. LOOK at the screenshot yourself (Read tool) and iterate at least twice — first render is never right. Check: nothing clipped, curves smooth, dots visible on the MI→inverter and battery→inverter and inverter→house flows, stat capsules aligned.
3. Report screenshot path + iterations done.
