# Dashboard v2 — "living dashboard" (data drives form)

Redesign of Dashboard mode only. Flow and Flow+Chart modes untouched. Visual/layout only — no protocol changes.

## Core principle
The layout itself is the visualization. Card SIZE encodes magnitude, card TINT encodes direction, and idle nodes collapse to whispers. A glance from across the room answers: what's big right now, and which way is it going?

## 1. Card tiers (driven by |W|, per node, animated)
Three tiers, evaluated per poll with hysteresis (promote at |W| ≥ 50 W, demote at < 20 W — no flapping):

- **HERO** (the largest |W| among active nodes, and any node ≥ 40% of the max): full card — 52pt badge, 34pt value, secondary line. Height ≈ 96pt.
- **ACTIVE** (above threshold, not hero): compact card — 40pt badge, 24pt value, secondary line. Height ≈ 72pt.
- **IDLE** (below threshold): slim row, NOT a card — just 16pt tinted icon + name + small value ("0 W" / "—") in one 24pt-high line at 55% opacity, hairline separator only. EV shows "EV — waiting" this way until nonzero.

Tier changes animate with `.spring(duration 0.6, bounce 0.15)` on frame/opacity; value fonts interpolate. Cards never reorder (fixed order: Solar PV, MI, Grid, Battery left; House, EV right) — only their heights/presence change, so nothing jumps around spatially.

## 2. Semantic tint (direction) layered on identity color
Each node keeps its identity hue in the badge icon. The CARD tint (stroke, background wash at ~8%, value color, connector) becomes semantic:

- **Feeding the inverter** (source: PV/MI producing, battery discharging, grid importing*): green wash — a warm spring green (not neon; e.g. hue ~135, sat modest).
- **Drawing from the inverter** (sink: house, EV, battery charging): warm coral/ember wash (hue ~15).
- *Grid exception (established convention + user's existing capsules): import = coral (costs money), export = teal-green (earning). i.e. grid follows money, not physics.
- Idle: neutral gray, no wash.

The big value text takes the semantic color; secondary stays secondary. Badge glow color = semantic color when active.

## 3. Kill the dead middle
- Window narrows: Dashboard = 620×400 at scale 1.0 (was 770).
- Connectors become the spine: full uninterrupted glowing runs from each card's edge to the inverter circle — they now span real distance and carry the existing dynamic width/dots (keep the |W|-scaled thickness, dot count, speed). Connector color = the node's semantic color.
- Inverter circle stays centered in the corridor; corridor width ≈ 150pt — tight enough that lines read as connections, not decoration.

## 4. Spacing rhythm (kill the monotony)
- Column outer padding 20pt; between cards in a column 10pt; between a card and an idle slim row 6pt; idle rows cluster together at the column bottom (Solar PV idle drifts below active ones? NO — keep fixed order, but idle rows have tighter mutual spacing so actives visually cluster and idles form a quiet footer group).
- Cards: inner padding 14pt horizontal / 12pt vertical (currently uniform-cramped).
- Bottom stat bar: add 4pt more breathing above, hairline stays.

## 5. Micro-behavior
- Value changes: keep `.contentTransition(.numericText())`.
- Hero card gets a very subtle animated sheen or 1pt brighter stroke — one distinguishing detail, no pulsing.
- When everything is idle (grid down, night, no load — rare), all cards go ACTIVE-compact neutral so the widget never looks broken.

## Hard constraints
- Dashboard mode only; Flow / Flow+Chart / sizes / menu / window level / corners unchanged.
- No card reordering, no layout thrash: heights animate smoothly, hysteresis mandatory.
- Don't touch SolarmanClient.swift or register decode.

## Verification
1. Build, relaunch preserving mode/size.
2. Self-capture at Small and Medium during live load; confirm: hero = biggest mover (House or MI right now), EV + Solar PV rendered as slim rows, green wash on MI/battery-discharge, coral on House, grid teal when exporting.
3. Capture twice ~60s apart while load changes (kettle/oven) to show tier growth actually animating (two captures differing).
4. No truncation at Small in all tiers; corners clean.
5. Commit+push ("Dashboard v2: magnitude-driven tiers + semantic tint"). No release.
