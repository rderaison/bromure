import Foundation
import SQLite3

/// Persistent MAC→IP lease table for the in-process DHCP server in
/// `VMNetSwitch`. Without it, leases live only in memory, so every agent
/// restart re-hands addresses from the top of the pool and a profile's VM can
/// land on a different IP. Backing the leases with sqlite lets us offer a MAC
/// the same address it held last time, "as often as possible" — it only moves
/// if that address is already taken or falls outside the current subnet.
///
/// Keyed by the 48-bit MAC packed into a UInt64 (the same representation the
/// switch uses internally). IPv4 is stored as a host-order UInt32.
public final class DHCPLeaseStore {
    private var db: OpaquePointer?
    private var selectStmt: OpaquePointer?
    private var upsertStmt: OpaquePointer?
    private let lock = NSLock()
    public let url: URL
    /// Max rows kept. There are only ~253 leasable addresses in a /24, so once
    /// the table fills we drop the least-recently-used MACs (stale profiles)
    /// rather than letting it grow without bound.
    private let capacity: Int

    public init?(url: URL, capacity: Int = 253) {
        self.url = url
        self.capacity = max(1, capacity)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(
            url.path, &db,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK
        else { return nil }
        exec("PRAGMA journal_mode = WAL")
        exec("PRAGMA synchronous = NORMAL")
        exec("""
            CREATE TABLE IF NOT EXISTS leases (
                mac INTEGER PRIMARY KEY,
                ip INTEGER NOT NULL,
                updated_at REAL NOT NULL
            );
            """)
        selectStmt = prepare("SELECT ip FROM leases WHERE mac = ?")
        upsertStmt = prepare(
            "INSERT OR REPLACE INTO leases (mac, ip, updated_at) VALUES (?, ?, ?)")
    }

    deinit {
        sqlite3_finalize(selectStmt)
        sqlite3_finalize(upsertStmt)
        if let db { sqlite3_close_v2(db) }
    }

    /// The IPv4 (host-order UInt32) this MAC was last leased, if any.
    public func ip(forMAC mac: UInt64) -> UInt32? {
        lock.lock(); defer { lock.unlock() }
        guard let stmt = selectStmt else { return nil }
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        sqlite3_bind_int64(stmt, 1, Int64(bitPattern: mac))
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return UInt32(truncatingIfNeeded: sqlite3_column_int64(stmt, 0))
    }

    /// Persist (or refresh) the lease for a MAC.
    public func record(mac: UInt64, ip: UInt32) {
        lock.lock(); defer { lock.unlock() }
        guard let stmt = upsertStmt else { return }
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        sqlite3_bind_int64(stmt, 1, Int64(bitPattern: mac))
        sqlite3_bind_int64(stmt, 2, Int64(ip))
        sqlite3_bind_double(stmt, 3, Date().timeIntervalSince1970)
        _ = sqlite3_step(stmt)
        // Cap the table: keep the `capacity` most-recently-leased MACs, evict the
        // rest (oldest by updated_at). The MAC we just touched is newest, so it
        // always survives.
        exec("DELETE FROM leases WHERE mac NOT IN "
             + "(SELECT mac FROM leases ORDER BY updated_at DESC LIMIT \(capacity))")
    }

    /// All persisted leases as (mac, ip) pairs — for diagnostics / a CLI dump.
    public func all() -> [(mac: UInt64, ip: UInt32)] {
        lock.lock(); defer { lock.unlock() }
        guard let stmt = prepare("SELECT mac, ip FROM leases ORDER BY ip") else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [(UInt64, UInt32)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append((UInt64(bitPattern: sqlite3_column_int64(stmt, 0)),
                        UInt32(truncatingIfNeeded: sqlite3_column_int64(stmt, 1))))
        }
        return out
    }

    // MARK: - sqlite helpers

    private func exec(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func prepare(_ sql: String) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        return stmt
    }
}
