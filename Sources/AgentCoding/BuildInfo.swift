#if os(macOS)
import AppKit

/// Which build this is — stamped into Info.plist by
/// scripts/stamp-build-info.sh (Jenkins build number, commit, date).
enum BuildInfo {
    static func value(_ key: String) -> String? {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// "Jenkins #412 · 69919d6a · 2026-10-09 01:12 UTC"; nil for an
    /// unstamped binary (swift run).
    static var summary: String? {
        let parts = ["BromureBuild", "BromureCommit", "BromureBuildDate"].compactMap(value)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// For /state: what a client (or a debugging session) can read remotely.
    static var dictionary: [String: String] {
        var d: [String: String] = [:]
        if let v = value("CFBundleShortVersionString") { d["version"] = v }
        if let v = value("BromureBuild") { d["build"] = v }
        if let v = value("BromureCommit") { d["commit"] = v }
        if let v = value("BromureBuildDate") { d["date"] = v }
        return d
    }

    /// The standard About panel, with the build in place of the bare
    /// CFBundleVersion in parentheses.
    @MainActor static func showAboutPanel() {
        var options: [NSApplication.AboutPanelOptionKey: Any] = [:]
        if let s = summary { options[.version] = s }
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: options)
    }
}
#endif
