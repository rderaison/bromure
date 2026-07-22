import Foundation

/// Stable credential-ID conventions consulted by the consent broker + token
/// swap. Pure string helpers — shared so the fat client's mirrored profiles /
/// token plans decode on iOS too.
public enum ConsentCredentialID {
    public static func primaryToolAPIKey(tool: String) -> String { "tool-apikey:" + tool }
    public static func aws() -> String                            { "aws" }
    public static func digitalOcean() -> String                   { "do-pat" }
    public static func linear() -> String                         { "linear-key" }
    public static func sshKey(_ id: String) -> String             { "ssh:" + id }
    public static func bromureSSHKey() -> String                  { "ssh:bromure-auto" }
    public static func gitHTTPS(_ id: UUID) -> String             { "git-https:" + id.uuidString }
    public static func manualToken(_ id: UUID) -> String          { "manual:" + id.uuidString }
    public static func dockerRegistry(_ id: UUID) -> String       { "docker:" + id.uuidString }
    public static func kubeconfig(_ id: UUID) -> String           { "kube:" + id.uuidString }
    public static func httpDatabase(_ id: UUID) -> String         { "db:" + id.uuidString }
}
