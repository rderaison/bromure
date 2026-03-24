import Foundation

/// Manages a pool of locally-administered MAC addresses that are recycled across VM sessions.
///
/// Addresses are stored on disk (NOT in iCloud) so the same small set of MACs is reused,
/// keeping vmnet's DHCP lease table small. In-memory tracking prevents two concurrent VMs
/// from sharing the same MAC.
///
/// If the user typically runs 2 sessions, only ~3 MACs are ever needed (2 active + 1 warm).
public final class MACAddressPool: @unchecked Sendable {
    public static let shared = MACAddressPool()

    private let fileURL: URL
    private let lock = NSLock()
    /// All known addresses in the pool (persisted on disk).
    private var addresses: [String] = []
    /// Currently claimed addresses (in-memory only — resets on app restart).
    private var claimed: Set<String> = []

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bromure", isDirectory: true)
        self.fileURL = dir.appendingPathComponent("mac-pool.json")
        load()
    }

    /// Claim a MAC address for a VM session.
    ///
    /// Returns a previously-used address if one is available, otherwise generates a new one
    /// and persists it to disk. This ensures the fewest possible MACs are used over time,
    /// preventing vmnet DHCP lease pool exhaustion.
    /// Maximum number of MAC addresses to keep. Caps the vmnet DHCP lease table.
    /// Typical usage: 2 active sessions + 1 warm = 3, with headroom for transient claims.
    private static let maxAddresses = 32

    public func claim() -> String? {
        lock.lock()
        defer { lock.unlock() }

        // Reuse an existing unclaimed address
        if let available = addresses.first(where: { !claimed.contains($0) }) {
            claimed.insert(available)
            print("[MACPool] claimed (reused): \(available) (\(claimed.count)/\(addresses.count) in use)")
            return available
        }

        // Refuse to grow beyond the cap — vmnet DHCP lease table is finite
        if addresses.count >= Self.maxAddresses {
            print("[MACPool] ERROR: all \(Self.maxAddresses) addresses in use — cannot create more VMs")
            return nil
        }

        // Generate and persist a new one
        let mac = Self.generateMAC()
        addresses.append(mac)
        claimed.insert(mac)
        save()
        print("[MACPool] claimed (new): \(mac) (\(claimed.count)/\(addresses.count) in use)")
        return mac
    }

    /// Release a MAC address back to the pool for reuse.
    public func release(_ mac: String) {
        lock.lock()
        defer { lock.unlock() }
        claimed.remove(mac)
        print("[MACPool] released: \(mac) (\(claimed.count)/\(addresses.count) in use)")
    }

    // MARK: - Private

    /// Generate a locally-administered unicast MAC address.
    /// First octet 0x02 = locally administered + unicast (same convention as VZMACAddress.randomLocallyAdministered).
    private static func generateMAC() -> String {
        let b1 = UInt8(arc4random_uniform(256))
        let b2 = UInt8(arc4random_uniform(256))
        let b3 = UInt8(arc4random_uniform(256))
        let b4 = UInt8(arc4random_uniform(256))
        let b5 = UInt8(arc4random_uniform(256))
        return String(format: "02:%02x:%02x:%02x:%02x:%02x", b1, b2, b3, b4, b5)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let arr = try? JSONDecoder().decode([String].self, from: data) else { return }
        addresses = arr
    }

    private func save() {
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(addresses) else { return }
        try? data.write(to: fileURL, options: .atomic)
        // Exclude from backup (Time Machine, etc.) — this is local-only data
        var url = fileURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}
