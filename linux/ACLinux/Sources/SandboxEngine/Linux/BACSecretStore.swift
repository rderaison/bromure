import Foundation

/// Secrets by (service, account): what the Keychain items of macOS become on
/// Linux (linux/SECRET_STORE.md). The shared SandboxEngine and AgentCoding
/// code calls this; the daemon plugs in its encrypted per-user vault
/// (`VaultItems`) at start. Before that, or in a tool without a vault,
/// nothing is kept and storing throws.
// @port-skip linux-only: the Keychain's stand-in (macOS calls SecItem directly)
public enum BACSecretStore {
    /// Where items go: set once by the host process.
    public protocol Backend: Sendable {
        func store(service: String, account: String, data: Data) throws
        func read(service: String, account: String) -> Data?
        func delete(service: String, account: String)
    }

    public enum StoreError: Error, CustomStringConvertible {
        case noBackend
        // @port-skip linux-only: secret store
        public var description: String { "no secret store is configured in this process" }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _backend: Backend?

    // @port-skip linux-only: secret store
    public static var backend: Backend? {
        get { lock.lock(); defer { lock.unlock() }; return _backend }
        set { lock.lock(); _backend = newValue; lock.unlock() }
    }

    // @port-skip linux-only: secret store
    public static func store(service: String, account: String, data: Data) throws {
        guard let b = backend else { throw StoreError.noBackend }
        try b.store(service: service, account: account, data: data)
    }

    // @port-skip linux-only: secret store
    public static func read(service: String, account: String) -> Data? {
        backend?.read(service: service, account: account)
    }

    // @port-skip linux-only: secret store
    public static func delete(service: String, account: String) {
        backend?.delete(service: service, account: account)
    }
}
