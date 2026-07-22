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
