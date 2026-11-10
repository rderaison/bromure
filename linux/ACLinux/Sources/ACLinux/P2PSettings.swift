import Foundation

/// Whether a multi-user server's users may be reached over P2P, the admin's
/// call (`bromure-ac admin p2p on|off`): /etc/bromure-ac/p2p.json, root's,
/// readable by every daemon. Off (or missing): the gateway serves no P2P
/// ingress and no user's daemon announces anything. On: each user's ingress
/// listens on `bindAddress` (the gateway's when the admin turned it on),
/// so P2P doesn't reach further than the gateway itself does.
// @port-skip linux-only: the multi-user server's P2P switch
public struct P2PSettings: Codable, Equatable, Sendable {
    public var enabled = false
    /// Where users' ingress ports listen; nil or "0.0.0.0": every interface.
    public var bindAddress: String?

    // @port-skip linux-only: see P2PSettings
    public init(enabled: Bool = false, bindAddress: String? = nil) {
        self.enabled = enabled
        self.bindAddress = bindAddress
    }

    public static let systemPath = "/etc/bromure-ac/p2p.json"

    /// Where a daemon reads it: the system file, or BROMURE_P2P_SETTINGS
    /// (tests). The gateway reads the system file only.
    // @port-skip linux-only: see P2PSettings
    public static var defaultPath: String {
        ProcessInfo.processInfo.environment["BROMURE_P2P_SETTINGS"] ?? systemPath
    }

    /// The file's settings; missing, unreadable, or (`trusted`) not root's
    /// alone (the file and its dir owned by root, writable by no one else):
    /// off.
    // @port-skip linux-only: see P2PSettings
    public static func load(_ path: String = defaultPath, trusted: Bool? = nil) -> P2PSettings {
        let mustBeRoots = trusted ?? (path == systemPath)
        if mustBeRoots {
            for p in [path, (path as NSString).deletingLastPathComponent] {
                var st = stat()
                guard lstat(p, &st) == 0, st.st_uid == 0, st.st_mode & 0o022 == 0, st.st_mode & S_IFMT != S_IFLNK else {
                    return P2PSettings()
                }
            }
        }
        return (try? Data(contentsOf: URL(fileURLWithPath: path))).flatMap { try? JSONDecoder().decode(P2PSettings.self, from: $0) }
            ?? P2PSettings()
    }

    // @port-skip linux-only: see P2PSettings
    public func save(_ path: String = defaultPath) throws {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(self).write(to: URL(fileURLWithPath: path), options: .atomic)
        chmod(path, 0o644)
    }
}
