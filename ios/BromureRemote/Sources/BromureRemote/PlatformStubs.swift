import Foundation
import SwiftUI

// MARK: - iOS stubs for macOS-only app internals
//
// A handful of shared files reference app-wide constants and helpers that live
// in files the iOS target doesn't compile (the local-inference subprocess
// manager, the SPM resource bundle). These are the minimal iOS-side stand-ins.

/// The MITM proxy's synthetic hostname for local inference. On macOS this is a
/// constant on the (subprocess-heavy, macOS-only) `InferenceService`; the fat
/// client only needs the value, to recognize the host in mirrored profiles.
enum InferenceService {
    public static let localMitmHost = "bromure.llm"
}

/// The resource bundle shared code loads bundled SVG icons / highlighter assets
/// from. On macOS it's the SPM module bundle populated by build.sh; the iOS
/// client ships no such assets, so icons fall back to SF Symbols and the
/// bundle lookups simply miss.
let acResourceBundle = Bundle.main

// MARK: - Enterprise-enrollment stubs (P2P identity)
//
// The full enrollment store (Enrollment.swift) pulls in X509 / SandboxEngine
// and is macOS-only. The iOS client uses the browser-enrolled DEVICE identity
// path for P2P, never the enterprise install token, so these stand-ins always
// report "not enrolled" and the `.enterprise` branch is skipped.

struct BACInstall: Codable, Equatable, Identifiable {
    let installId: String
    let orgSlug: String
    let userId: String
    let serverURL: URL
    var id: String { installId }
}

enum BACEnrollmentStore {
    static func load() -> BACInstall? { nil }
    static func loadInstallToken() -> String? { nil }
}

/// The egress firewall model lives in SandboxEngine (macOS-only), and the
/// shared Profile / guardrails files reference it. The fat client never
/// ENFORCES egress rules — the host does — so the stand-in only has to
/// carry the field through the mirrored profile: parsing always yields
/// the allow-all placeholder.
public struct EgressPolicy: Sendable, Equatable, Codable {
    public static let allowAll = EgressPolicy()
    public static func parse(_ rules: String) throws -> EgressPolicy { allowAll }
    public var isActive: Bool { false }
    public func permitsMethod(hostnames: [String], port: UInt16,
                              method: String) -> Bool { true }
}

/// The host-side config-file scanner (ConfigScan.swift) walks the Mac's
/// dotfiles and is macOS-only. The mirrored editor needs exactly one helper
/// from it — the "N setting(s)" subtitle count for imported config files —
/// duplicated here verbatim.
enum ConfigScan {
    /// Settings in a sanitized config body — non-blank lines that aren't
    /// comments or section headers. Only ever shown to the user as "N more
    /// setting(s)", so an approximate count is fine.
    static func settingCount(_ body: String) -> Int {
        body.split(whereSeparator: \.isNewline).reduce(0) { n, line in
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.isEmpty || l.hasPrefix("#") || l.hasPrefix(";") || l.hasPrefix("[") { return n }
            return n + 1
        }
    }
}
