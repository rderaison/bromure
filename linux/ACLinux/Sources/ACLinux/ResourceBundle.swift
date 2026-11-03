import Foundation

/// The app's resources (catalog.json, img-catalog.json, vm-setup/, ...) for
/// the shared code that reads them (macOS: the SPM resource bundle in the
/// .app). A plain directory: BROMURE_AC_RESOURCES, else the installed copy
/// in <data>/bromure-ac/resources, else, in a development build, the
/// source tree's Sources/AgentCoding/Resources.
// @port-skip linux-only: stand-in for BromureAC.swift's acResourceBundle (an .app bundle there)
let acResourceBundle: Bundle = {
    let env = ProcessInfo.processInfo.environment
    let data = env["XDG_DATA_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory() + "/.local/share"
    let source = URL(fileURLWithPath: #filePath)   // .../linux/ACLinux/Sources/ACLinux/ResourceBundle.swift
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/AgentCoding/Resources").path
    let candidates = [env["BROMURE_AC_RESOURCES"], data + "/bromure-ac/resources", source]
    for case let dir? in candidates where FileManager.default.fileExists(atPath: dir + "/catalog.json") {
        if let b = Bundle(path: dir) { return b }
    }
    return Bundle(path: source) ?? Bundle.main
}()
