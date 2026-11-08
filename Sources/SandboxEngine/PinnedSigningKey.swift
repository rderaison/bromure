import Foundation

/// The ed25519 public key Bromure's signed catalogs (images, kernel sentry
/// modules) verify against — the same Sparkle key that signs app updates.
/// Read from Info.plist (SUPublicEDKey) when running from an app bundle; the
/// constant covers bare-binary contexts (swift build output, unit tests, the
/// Linux daemon) and MUST match Sources/Browser/Info.plist and
/// Sources/AgentCoding/Info.plist (they carry the same key).
public enum PinnedSigningKey {
    public static var publicKeyBase64: String {
        (Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)
            ?? "G1ofi8zFFgNyE5Momw+eoWeiBt8NGCiKQWAs+YBvZK8="
    }
}
