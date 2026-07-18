import Foundation
import SQLite3

/// Rolling on-disk sample history in SQLite (system libsqlite3, no deps).
///
/// One row per successful poll at ~/Library/Application Support/DeyeWidget/history.db.
/// All DB access is serialized on a private queue so the single connection is
/// only ever touched from one thread. Writes are fire-and-forget so a slow or
/// failed disk write can never stall or crash the 5 s poll loop.
///
/// Gaps in the `ts` series ARE the outage record: rows exist only for polls that
/// succeeded, so a missing stretch means the logger/grid was unreachable.
final class HistoryStore: @unchecked Sendable {
    /// Rolling window. Keep this many days; older rows are pruned at launch and
    /// hourly. ponytail: constant, not a setting — nobody needs a knob for this.
    static let retentionDays = 5

    let url: URL
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.deyewidget.history")

    /// Full read/write store used by the running app. Creates the dir + table,
    /// enables WAL, and prunes once at launch. Returns nil if the DB can't open.
    init?() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DeyeWidget", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.url = base.appendingPathComponent("history.db")

        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK else {
            Self.logErr("open failed: \(Self.msg(handle))")
            sqlite3_close(handle)
            return nil
        }
        self.db = handle
        exec("PRAGMA journal_mode=WAL;")
        exec("PRAGMA synchronous=NORMAL;")
        exec("""
            CREATE TABLE IF NOT EXISTS samples(
              ts INTEGER PRIMARY KEY,
              house REAL, mi REAL, pv REAL, battery REAL, grid REAL,
              soc REAL, grid_v REAL, freq REAL, temp REAL, batt_v REAL
            );
            """)
        prune()
    }

    /// Read-only store for the CLI (`--history` / `--gaps`). Never writes, so it
    /// coexists with the running app which owns the logger's single TCP socket —
    /// the CLI only touches the DB file (WAL permits concurrent readers).
    init?(readOnly: Bool) {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DeyeWidget", isDirectory: true)
        self.url = base.appendingPathComponent("history.db")
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            Self.logErr("open (readonly) failed: \(Self.msg(handle))")
            sqlite3_close(handle)
            return nil
        }
        self.db = handle
    }

    deinit { if let db { sqlite3_close(db) } }

    // MARK: - Writing

    /// Persist one snapshot. Fire-and-forget on the private queue: the poll loop
    /// never waits on the disk and a write error only logs to stderr.
    func record(_ d: InverterData, at time: Date = Date()) {
        let ts = Int64(time.timeIntervalSince1970)
        queue.async { [weak self] in self?.insert(ts, d) }
    }

    private func insert(_ ts: Int64, _ d: InverterData) {
        let sql = """
            INSERT OR REPLACE INTO samples
              (ts, house, mi, pv, battery, grid, soc, grid_v, freq, temp, batt_v)
            VALUES (?,?,?,?,?,?,?,?,?,?,?);
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            Self.logErr("insert prepare failed: \(Self.msg(db))")
            return
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, ts)
        sqlite3_bind_double(stmt, 2, Double(d.loadPower))
        sqlite3_bind_double(stmt, 3, Double(d.miPower))
        sqlite3_bind_double(stmt, 4, Double(d.pvTotal))
        sqlite3_bind_double(stmt, 5, Double(d.batteryPower))
        sqlite3_bind_double(stmt, 6, Double(d.gridPower))
        sqlite3_bind_double(stmt, 7, Double(d.soc))
        sqlite3_bind_double(stmt, 8, d.gridVoltage)
        sqlite3_bind_double(stmt, 9, d.gridFrequency)
        sqlite3_bind_double(stmt, 10, d.inverterTemp)
        sqlite3_bind_double(stmt, 11, d.batteryVoltage)
        if sqlite3_step(stmt) != SQLITE_DONE {
            Self.logErr("insert step failed: \(Self.msg(db))")
        }
    }

    /// Delete rows older than the retention window. Cheap; run at launch + hourly.
    func prune() {
        let cutoff = Int64(Date().timeIntervalSince1970) - Int64(Self.retentionDays) * 86_400
        queue.async { [weak self] in
            guard let self, let db = self.db else { return }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "DELETE FROM samples WHERE ts < ?;", -1, &stmt, nil) == SQLITE_OK else {
                Self.logErr("prune prepare failed: \(Self.msg(db))")
                return
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, cutoff)
            if sqlite3_step(stmt) != SQLITE_DONE {
                Self.logErr("prune step failed: \(Self.msg(db))")
            }
        }
    }

    // MARK: - Reading

    /// Rows from the last `minutes`, oldest first, mapped to chart samples — used
    /// to seed the in-memory Power Profile so it's full right after a relaunch.
    func recentSamples(minutes: Int) -> [PowerSample] {
        let since = Int64(Date().timeIntervalSince1970) - Int64(minutes) * 60
        var out: [PowerSample] = []
        queue.sync {
            guard let db else { return }
            var stmt: OpaquePointer?
            let sql = "SELECT ts, house, mi, battery, grid, soc FROM samples WHERE ts >= ? ORDER BY ts ASC;"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, since)
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(PowerSample(
                    time: Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 0))),
                    house: sqlite3_column_double(stmt, 1),
                    mi: sqlite3_column_double(stmt, 2),
                    battery: sqlite3_column_double(stmt, 3),
                    grid: sqlite3_column_double(stmt, 4),
                    soc: sqlite3_column_double(stmt, 5)
                ))
            }
        }
        return out
    }

    /// Row count (diagnostics).
    func count() -> Int {
        var n = 0
        queue.sync {
            guard let db else { return }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM samples;", -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            if sqlite3_step(stmt) == SQLITE_ROW { n = Int(sqlite3_column_int64(stmt, 0)) }
        }
        return n
    }

    /// All columns since `seconds` ago, oldest first. Raw rows for CSV export.
    func rows(sinceSecondsAgo seconds: Int) -> [Row] {
        let since = Int64(Date().timeIntervalSince1970) - Int64(seconds)
        var out: [Row] = []
        queue.sync {
            guard let db else { return }
            var stmt: OpaquePointer?
            let sql = """
                SELECT ts, house, mi, pv, battery, grid, soc, grid_v, freq, temp, batt_v
                FROM samples WHERE ts >= ? ORDER BY ts ASC;
                """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, since)
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(Row(
                    ts: sqlite3_column_int64(stmt, 0),
                    house: sqlite3_column_double(stmt, 1),
                    mi: sqlite3_column_double(stmt, 2),
                    pv: sqlite3_column_double(stmt, 3),
                    battery: sqlite3_column_double(stmt, 4),
                    grid: sqlite3_column_double(stmt, 5),
                    soc: sqlite3_column_double(stmt, 6),
                    gridV: sqlite3_column_double(stmt, 7),
                    freq: sqlite3_column_double(stmt, 8),
                    temp: sqlite3_column_double(stmt, 9),
                    battV: sqlite3_column_double(stmt, 10)
                ))
            }
        }
        return out
    }

    struct Row {
        let ts: Int64
        let house, mi, pv, battery, grid, soc, gridV, freq, temp, battV: Double
    }

    // MARK: - Helpers

    private func exec(_ sql: String) {
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            Self.logErr("exec failed for [\(sql.prefix(40))…]: \(Self.msg(db))")
        }
    }

    private static func msg(_ db: OpaquePointer?) -> String {
        guard let db, let c = sqlite3_errmsg(db) else { return "unknown" }
        return String(cString: c)
    }

    private static func logErr(_ m: String) {
        FileHandle.standardError.write("[HistoryStore] \(m)\n".data(using: .utf8)!)
    }
}
