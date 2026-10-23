import Foundation

/// What the battery card says about time left. Computed from the on-disk
/// history at most once a minute (see DataPoller), never per frame.
enum BatteryETA: Equatable {
    case discharging(until: Date?, solarAt: Date?, learning: Bool) // until == nil → lasts past solarAt
    case charging(fullBy: Date)
    case reserve(since: Date?)    // at floor, house on grid
    case none                     // idle / full / not enough data → keep old UI text
}

/// Pure estimate logic: no IO, no clock, so `--etacheck` can drive it with
/// synthetic rows. Battery W is signed: + discharge, − charge.
enum BatteryEstimate {
    static let step: TimeInterval = 300          // 5-min walk step
    static let maxHorizon: TimeInterval = 36 * 3600
    static let maxGap: Int64 = 60                // dt above this is an outage, not energy
    static let solarMargin: TimeInterval = 3600
    static var tau: TimeInterval = 7200  // how fast tonight's scale fades back to typical

    static func compute(now: Date, soc: Int, batteryW: Int, rows: [HistoryStore.Row],
                        floor: Double = 35, calendar cal: Calendar = .current) -> BatteryETA {
        let socD = Double(soc)
        let nowTs = Int64(now.timeIntervalSince1970)

        // E2: sitting at the floor, house on grid.
        if socD <= floor + 0.5 && abs(batteryW) < 100 {
            guard let i = rows.lastIndex(where: { $0.soc > floor + 0.5 }) else { return .reserve(since: nil) }
            let ts = i + 1 < rows.count ? rows[i + 1].ts : rows[i].ts
            return .reserve(since: Date(timeIntervalSince1970: Double(ts)))
        }

        guard let whPct = whPerPercent(rows: rows, floor: floor) else { return .none }

        // E1: charging. ponytail: linear to 100 %, ignores the CV taper near full.
        if batteryW < -100 && soc < 98 {
            let recent = rows.filter { $0.ts >= nowTs - 1800 }
            var chargeW = recent.isEmpty ? 0 : recent.map { max(-$0.battery, 0) }.reduce(0, +) / Double(recent.count)
            if chargeW < 100 { chargeW = Double(-batteryW) }
            let hours = (100 - socD) * whPct / chargeW
            return .charging(fullBy: now.addingTimeInterval(hours * 3600))
        }

        guard batteryW > 100 && socD > floor + 0.5 else { return .none }

        let usable = (socD - floor) * whPct
        let solarAt = solarStart(now: now, rows: rows, calendar: cal)
        let learning = nightCount(rows: rows, calendar: cal) < 2

        // Load in W as a function of the walk time.
        let load: (Date) -> Double
        if learning {
            let lastHour = rows.filter { $0.ts >= nowTs - 3600 }
            var mean = lastHour.isEmpty ? 0 : lastHour.map { max($0.battery, 0) }.reduce(0, +) / Double(lastHour.count)
            if mean < 100 { mean = Double(batteryW) }
            load = { _ in mean }
        } else {
            let p = hourlyProfile(rows: rows, before: nowTs - 7200, floor: floor, calendar: cal)
            // The battery also feeds inverter overhead (~100+ W), so it drains faster
            // than the house load shows. Learn that ratio from discharge samples.
            let dis = rows.filter { $0.battery > 100 && $0.house > 100 }
            let bSum = dis.reduce(0) { $0 + $1.battery }, hSum = dis.reduce(0) { $0 + $1.house }
            let loss = hSum > 0 ? min(max(bSum / hSum, 1.0), 1.5) : 1.0
            let last2h = rows.filter { $0.ts >= nowTs - 7200 }
            var k = 1.0
            if !last2h.isEmpty {
                let actual = last2h.map { max($0.house, 0) }.reduce(0, +) / Double(last2h.count)
                let typical = last2h.map { p[hour($0.ts, cal)] }.reduce(0, +) / Double(last2h.count)
                if typical > 0 { k = min(max(actual / typical, 0.5), 2.0) }
            }
            // Evening (17:00-24:00): a busy or quiet evening tends to stay that way until
            // bedtime, so tonight's scale holds until midnight, then a typical night.
            // Other hours: the deviation fades out over ~2 h.
            // ponytail: midnight is a fixed bedtime guess; learn it if it misleads.
            let evening = cal.component(.hour, from: now) >= 17
            let midnight = cal.nextDate(after: now, matching: DateComponents(hour: 0), matchingPolicy: .nextTime) ?? now
            load = { t in
                let scale = evening ? (t < midnight ? k : 1)
                                    : 1 + (k - 1) * exp(-t.timeIntervalSince(now) / tau)
                return p[cal.component(.hour, from: t)] * scale * loss
            }
        }

        var energy = usable
        var t = now
        while t.timeIntervalSince(now) < maxHorizon {
            // Walk past solar start too: only call it "lasts until solar" with an
            // hour to spare, since a late or cloudy morning eats a thin margin.
            if let s = solarAt, t >= s.addingTimeInterval(solarMargin) { break }
            let w = max(load(t), 1)
            let need = w * step / 3600
            if need >= energy {
                let until = t.addingTimeInterval(step * energy / need)
                return .discharging(until: until, solarAt: solarAt, learning: learning)
            }
            energy -= need
            t = t.addingTimeInterval(step)
        }
        return .discharging(until: nil, solarAt: solarAt, learning: learning)
    }

    /// Learned Wh per 1 % SOC over discharge stretches (battery > 100 W, soc above
    /// floor). nil until the stretches cover >= 10 % of SOC drop.
    static func whPerPercent(rows: [HistoryStore.Row], floor: Double) -> Double? {
        var energy = 0.0, drop = 0.0
        var startSoc: Double? = nil, lastSoc = 0.0
        func close() { if let s = startSoc { drop += max(s - lastSoc, 0) }; startSoc = nil }
        for i in rows.indices {
            let r = rows[i]
            guard r.battery > 100, r.soc > floor else { close(); continue }
            if startSoc != nil, i > 0, r.ts - rows[i - 1].ts <= maxGap {
                energy += rows[i - 1].battery * Double(r.ts - rows[i - 1].ts) / 3600
            } else {
                close()
                startSoc = r.soc
            }
            lastSoc = r.soc
        }
        close()
        guard drop >= 10 else { return nil }
        return min(max(energy / drop, 50), 2000)
    }

    /// P[hourOfDay] = mean house load W from rows older than `before`, skipping
    /// rows parked at the floor. Missing hours fall back to the overall mean.
    /// House load, not battery W: it is what the approved A3 backtest used
    /// (21:00 → ≈07:30 vs real 07:21); battery W predicts ≈06:35 there.
    /// Typical house W per hour of day: the mean of each (day, hour) bucket, then
    /// the median across days, so one odd night (heater left on) can't skew it.
    static func hourlyProfile(rows: [HistoryStore.Row], before: Int64, floor: Double,
                              calendar cal: Calendar) -> [Double] {
        var buckets: [Int64: (sum: Double, n: Int)] = [:]   // key = hour-start timestamp
        for r in rows where r.ts < before && r.soc > floor + 1 {
            let key = r.ts - r.ts % 3600
            buckets[key, default: (0, 0)].sum += max(r.house, 0)
            buckets[key, default: (0, 0)].n += 1
        }
        var perHour = [[Double]](repeating: [], count: 24)
        for (key, b) in buckets where b.n >= 60 {             // >= ~5 min of samples
            perHour[hour(key, cal)].append(b.sum / Double(b.n))
        }
        func median(_ v: [Double]) -> Double {
            let s = v.sorted(), m = s.count / 2
            return s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2
        }
        let have = perHour.filter { !$0.isEmpty }.map(median)
        let fallback = have.isEmpty ? 0 : have.reduce(0, +) / Double(have.count)
        return perHour.map { $0.isEmpty ? fallback : median($0) }
    }

    static func solarStart(now: Date, rows: [HistoryStore.Row], calendar cal: Calendar) -> Date? {
        var firstByDay: [Date: TimeInterval] = [:]
        for r in rows where r.battery < -300 {
            let d = Date(timeIntervalSince1970: Double(r.ts))
            let h = cal.component(.hour, from: d)
            guard h >= 5 && h < 13 else { continue }
            let day = cal.startOfDay(for: d)
            if firstByDay[day] == nil { firstByDay[day] = d.timeIntervalSince(day) }
        }
        let tods = firstByDay.keys.sorted(by: >).prefix(3).compactMap { firstByDay[$0] }.sorted()
        guard !tods.isEmpty else { return nil }
        let median = tods.count % 2 == 1 ? tods[tods.count / 2]
                                         : (tods[tods.count / 2 - 1] + tods[tods.count / 2]) / 2
        let today = cal.startOfDay(for: now)
        var next = today.addingTimeInterval(median)
        if next <= now, let tomorrow = cal.date(byAdding: .day, value: 1, to: today) {
            next = tomorrow.addingTimeInterval(median)
        }
        return next
    }

    /// Distinct nights (any row 00:00-05:00 with battery > 100 W).
    static func nightCount(rows: [HistoryStore.Row], calendar cal: Calendar) -> Int {
        var days = Set<Date>()
        for r in rows where r.battery > 100 {
            let d = Date(timeIntervalSince1970: Double(r.ts))
            if cal.component(.hour, from: d) < 5 { days.insert(cal.startOfDay(for: d)) }
        }
        return days.count
    }

    private static func hour(_ ts: Int64, _ cal: Calendar) -> Int {
        cal.component(.hour, from: Date(timeIntervalSince1970: Double(ts)))
    }

    /// 24 h "HH:mm" in the user's time zone.
    static let clock: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        f.timeZone = .current
        f.dateFormat = "HH:mm"
        return f
    }()
}
