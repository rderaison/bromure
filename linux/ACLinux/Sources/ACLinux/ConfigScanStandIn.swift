import Foundation

/// What the shared GitConfigParse names from ConfigScan (the client's scan of
/// its own machine, not built here): the git credential it lifts out of a
/// URL. The server parses a workspace's imported .gitconfig for its identity.
// @port-skip linux-only: ConfigScan stays on the client; only its GitCred type
enum ConfigScan {
    struct GitCred: Equatable {
        let host: String
        let username: String
        let token: String
    }
}
