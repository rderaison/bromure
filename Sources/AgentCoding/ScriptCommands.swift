import AppKit
import Foundation

// MARK: - Helpers

/// All NSScriptCommands run on the main thread, so MainActor is sound.
private func onMain<T>(_ body: @MainActor () -> T) -> T {
    MainActor.assumeIsolated { body() }
}

private func acDelegate() -> ACAppDelegate? {
    onMain { NSApp.delegate as? ACAppDelegate }
}

private func findProfile(_ nameOrID: String) -> Profile? {
    onMain {
        guard let d = NSApp.delegate as? ACAppDelegate else { return nil }
        if let uuid = UUID(uuidString: nameOrID) {
            return d.profiles.first { $0.id == uuid }
        }
        return d.profiles.first { $0.name.lowercased() == nameOrID.lowercased() }
    }
}

private func encodeJSON(_ value: Any) -> String {
    guard JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
          let s = String(data: data, encoding: .utf8) else { return "{}" }
    return s
}

// MARK: - Inspection

@objc(BromureACGetAppStateCommand)
final class BromureACGetAppStateCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        ScriptCall(self).run("get app state")
    }
}

@objc(BromureACListProfilesCommand)
final class BromureACListProfilesCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        ScriptCall(self).run("list profiles")
    }
}

// MARK: - Profile management

@objc(BromureACCreateProfileCommand)
final class BromureACCreateProfileCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        ScriptCall(self).run("create ac profile")
    }
}

@objc(BromureACDeleteProfileCommand)
final class BromureACDeleteProfileCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        ScriptCall(self).run("delete ac profile")
    }
}

// MARK: - Window navigation

@objc(BromureACOpenProfileManagerCommand)
final class BromureACOpenProfileManagerCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        ScriptCall(self).run("open profile manager")
    }
}

@objc(BromureACOpenProfileEditorCommand)
final class BromureACOpenProfileEditorCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        ScriptCall(self).run("open ac profile editor")
    }
}

@objc(BromureACCloseProfileEditorCommand)
final class BromureACCloseProfileEditorCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        ScriptCall(self).run("close ac profile editor")
    }
}

@objc(BromureACSelectEditorCategoryCommand)
final class BromureACSelectEditorCategoryCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        ScriptCall(self).run("select editor category")
    }
}

@objc(BromureACGetEditorWindowIDCommand)
final class BromureACGetEditorWindowIDCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        ScriptCall(self).run("get editor window id")
    }
}

@objc(BromureACGetMainWindowIDCommand)
final class BromureACGetMainWindowIDCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        ScriptCall(self).run("get main window id")
    }
}

// (Locale switching is intentionally not exposed via AppleScript:
// writing AppleLanguages from a scripted invocation triggers macOS's
// "modify environment" TCC alert and kills the host. The screenshot
// script relaunches the app with `-AppleLanguages "(<code>)"` to
// achieve the same effect without the prompt.)

// MARK: - Profile JSON round-trip
//
// `get profile json` and `set profile json` are the wide bridge used
// by Tests/ac-e2e.mjs. They round-trip the full Profile via the same
// Codable used to persist profile.json on disk, which sidesteps the
// need to bridge 50+ individual fields — the test side composes JSON,
// the host applies it atomically. Secrets travel verbatim through
// this bridge ONLY on debug builds (BROMURE_DEBUG_CLAUDE, which the
// e2e suite sets to assert round-trips); otherwise the blob is
// scrubbed via ProfileSecrets.extract — same write-only contract as
// the control-socket export, so no code path emits cleartext secrets
// regardless of transport.

@objc(BromureACGetProfileJSONCommand)
final class BromureACGetProfileJSONCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        ScriptCall(self).run("get profile json")
    }
}

@objc(BromureACSetProfileJSONCommand)
final class BromureACSetProfileJSONCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        ScriptCall(self).run("set profile json")
    }
}

// MARK: - Profile setting (keyed accessor for common simple fields)
//
// Convenience over the JSON round-trip when a test just needs to flip
// one bool / pick one enum. Anything not listed here is reachable via
// `get profile json` / `set profile json`.

@objc(BromureACGetProfileSettingCommand)
final class BromureACGetProfileSettingCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        ScriptCall(self).run("get profile setting")
    }
}

@objc(BromureACSetProfileSettingCommand)
final class BromureACSetProfileSettingCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        ScriptCall(self).run("set profile setting")
    }
}

// MARK: - Session control

@objc(BromureACOpenSessionCommand)
final class BromureACOpenSessionCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        ScriptCall(self).run("open ac session")
    }
}

@objc(BromureACCloseSessionCommand)
final class BromureACCloseSessionCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        ScriptCall(self).run("close ac session")
    }
}

@objc(BromureACListSessionsCommand)
final class BromureACListSessionsCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        ScriptCall(self).run("list ac sessions")
    }
}

// MARK: - App-wide settings (UserDefaults)
//
// AC's per-app settings live in UserDefaults; the per-profile settings are
// reachable via `get/set profile setting`. The browser exposes a wider set
// (vm.memoryGB, vm.appearance, etc.); AC's current automation surface
// covers the keys the test suite actually needs.

private let acAppSettingDefaults: [String: () -> String] = [
    "automation.enabled":     { String(UserDefaults.standard.bool(forKey: "automation.enabled")) },
    "automation.port":        { String(UserDefaults.standard.integer(forKey: "automation.port")) },
    "automation.bindAddress": { UserDefaults.standard.string(forKey: "automation.bindAddress") ?? "127.0.0.1" },
    "managed.serverURL":      { UserDefaults.standard.string(forKey: "managed.serverURL") ?? "" },
    "managed.acIngestURL":    { UserDefaults.standard.string(forKey: "managed.acIngestURL") ?? "" },
    "remoteAccess.enabled":   { String(UserDefaults.standard.bool(forKey: "remoteAccess.enabled")) },
    "remoteAccess.port":      { String(UserDefaults.standard.integer(forKey: "remoteAccess.port")) },
    "remoteAccess.bindAddress": { UserDefaults.standard.string(forKey: "remoteAccess.bindAddress") ?? "0.0.0.0" },
]

@objc(BromureACGetAppSettingCommand)
final class BromureACGetAppSettingCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        ScriptCall(self).run("get ac app setting")
    }
}

@objc(BromureACSetAppSettingCommand)
final class BromureACSetAppSettingCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        ScriptCall(self).run("set ac app setting")
    }
}

// MARK: - The verbs, callable without AppleScript
//
// Every command above is a thin shell over `ScriptCall.run`, so the same
// verbs are reachable from the owner-only control socket too (`POST
// /scripting`, debug runs only) — which is how the fat-client E2E suite
// (Tests/ac-fatclient-e2e.mjs) drives a REMOTE app's scripting surface through
// the fat-client SSH tunnel, where AppleScript can't reach. Must run on the
// main thread (the bodies assume MainActor isolation).

struct ScriptCall {
    let directParameter: Any?
    let evaluatedArguments: [String: Any]?

    init(directParameter: Any?, evaluatedArguments: [String: Any]?) {
        self.directParameter = directParameter
        self.evaluatedArguments = evaluatedArguments
    }

    init(_ command: NSScriptCommand) {
        self.init(directParameter: command.directParameter,
                  evaluatedArguments: command.evaluatedArguments)
    }

    /// Run the verb named as in BromureAC.sdef ("get profile json", …).
    func run(_ verb: String) -> Any? {
        switch verb {
        case "get app state":
            return onMain {
                let d = NSApp.delegate as? ACAppDelegate
                let state: [String: Any] = [
                    "locale":          (UserDefaults.standard.array(forKey: "AppleLanguages") as? [String])?.first ?? "system",
                    // The unified window is the app's main window now (the old
                    // profile picker was folded into it); `mainWindow` only ever
                    // holds the transient setup/onboarding window.
                    "mainWindowOpen":  (d?.unifiedWindow?.isVisible ?? false) as Any,
                    "setupWindowOpen": (d?.mainWindow?.isVisible ?? false) as Any,
                    "editorOpen":      (d?.editorWindow?.isVisible ?? false) as Any,
                    "profileCount":    d?.profiles.count ?? 0,
                ]
                return encodeJSON(state) as Any
            }
        case "list profiles":
            return onMain {
                guard let d = NSApp.delegate as? ACAppDelegate else { return "[]" as Any }
                let arr: [[String: Any]] = d.profiles.map {
                    ["id": $0.id.uuidString,
                     "name": $0.name,
                     "color": $0.color.rawValue]
                }
                return encodeJSON(arr) as Any
            }
        case "create ac profile":
            return onMain {
                guard let d = NSApp.delegate as? ACAppDelegate else { return "error: app not ready" as Any }
                let name = directParameter as? String ?? ""
                guard !name.isEmpty else { return "error: name required" as Any }
                let colorRaw = evaluatedArguments?["color"] as? String
                let color = colorRaw.flatMap { ProfileColor(rawValue: $0) } ?? .blue
                let profile = Profile(name: name, tool: .claude, authMode: .token, color: color)
                do {
                    try d.store.save(profile)
                    d.profiles = d.store.loadAll()
                    return profile.id.uuidString as Any
                } catch {
                    return "error: \(error.localizedDescription)" as Any
                }
            }
        case "delete ac profile":
            return onMain {
                guard let d = NSApp.delegate as? ACAppDelegate else { return "error: app not ready" as Any }
                let key = directParameter as? String ?? ""
                guard let profile = findProfile(key) else { return "error: profile not found" as Any }
                guard !d.diskInUse(profile.id) else { return "error: the workspace is running — stop it first" as Any }
                try? d.store.delete(profile)
                d.profiles = d.store.loadAll()
                return "ok" as Any
            }
        case "open profile manager":
            return onMain {
                (NSApp.delegate as? ACAppDelegate)?.openProfileManagerAction(nil)
                return "ok" as Any
            }
        case "open ac profile editor":
            return onMain {
                guard let d = NSApp.delegate as? ACAppDelegate else { return "error: app not ready" as Any }
                let key = directParameter as? String ?? ""
                guard let profile = findProfile(key) else { return "error: profile not found" as Any }
                d.openEditorWindow(editing: profile)
                return "ok" as Any
            }
        case "close ac profile editor":
            return onMain {
                (NSApp.delegate as? ACAppDelegate)?.closeEditorWindow()
                return "ok" as Any
            }
        case "select editor category":
            let raw = (directParameter as? String ?? "").lowercased()
            guard !raw.isEmpty else { return "error: category required" as Any }
            // The editor view subscribes to this notification and updates
            // its selectedCategory @State on receipt.
            NotificationCenter.default.post(
                name: .bromureACSelectEditorCategory, object: raw)
            return "ok" as Any
        case "get editor window id":
            return onMain {
                let id = (NSApp.delegate as? ACAppDelegate)?.editorWindow?.windowNumber ?? 0
                return id as Any
            }
        case "get main window id":
            return onMain {
                // The unified window is the app's main window now (the picker was
                // folded into it). Fall back to the setup window if that's all
                // that's open (first-run, before any base image).
                let d = NSApp.delegate as? ACAppDelegate
                let id = d?.unifiedWindow?.windowNumber ?? d?.mainWindow?.windowNumber ?? 0
                return id as Any
            }
        case "get profile json":
            return onMain {
                guard let key = directParameter as? String, !key.isEmpty else {
                    return "error: profile name or UUID required" as Any
                }
                guard var profile = findProfile(key) else { return "error: profile not found" as Any }
                if ProcessInfo.processInfo.environment["BROMURE_DEBUG_CLAUDE"] == nil {
                    _ = ProfileSecrets.extract(stripping: &profile)
                }
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                guard let data = try? encoder.encode(profile),
                      let str = String(data: data, encoding: .utf8) else {
                    return "error: encode failed" as Any
                }
                return str as Any
            }
        case "set profile json":
            return onMain {
                guard let d = NSApp.delegate as? ACAppDelegate else { return "error: app not ready" as Any }
                guard let key = directParameter as? String, !key.isEmpty else {
                    return "error: profile name or UUID required" as Any
                }
                guard let json = evaluatedArguments?["toValue"] as? String, !json.isEmpty else {
                    return "error: JSON body required (… to value \"…\")" as Any
                }
                guard let existing = findProfile(key) else { return "error: profile not found" as Any }
                guard let bytes = json.data(using: .utf8) else { return "error: invalid UTF-8" as Any }
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                do {
                    var incoming = try decoder.decode(Profile.self, from: bytes)
                    // Preserve the original id so callers can't accidentally
                    // rebind the profile to a different identity (which would
                    // orphan the on-disk session disk + meta share).
                    incoming.id = existing.id
                    // Blank-keep: a blob round-tripped through the (scrubbed)
                    // get bridge carries empty secret fields — merge the stored
                    // secrets underneath so get→edit→set can't wipe them.
                    // Values the caller actually supplied still win.
                    var existingCopy = existing
                    var merged = ProfileSecrets.extract(stripping: &existingCopy)
                    var incomingCopy = incoming
                    merged.overlay(with: ProfileSecrets.extract(stripping: &incomingCopy))
                    merged.apply(to: &incoming)
                    // Minted credentials are the VM's, not the blob's: keep the
                    // stored ones (secrets included) whatever the blob carries.
                    incoming.mintedCredentials = existing.mintedCredentials
                    try d.store.update(incoming)
                    d.profiles = d.store.loadAll()
                    // Apply live to a running session (no reboot) — matching the
                    // GUI/automation save path. Without this an external edit via
                    // this bridge (e.g. flipping disableTransparentProxy) persists
                    // but never lands on the running VM until it restarts (ac-e2e
                    // 27.3).
                    d.applyLiveEditToRunningSession(incoming)
                    return "ok" as Any
                } catch {
                    return "error: \(error.localizedDescription)" as Any
                }
            }
        case "get profile setting":
            return onMain {
                let nameOrID = directParameter as? String ?? ""
                let k = evaluatedArguments?["key"] as? String ?? ""
                guard let p = findProfile(nameOrID) else { return "error: profile not found" as Any }
                switch k {
                case "name":              return p.name as Any
                case "color":             return p.color.rawValue as Any
                case "comments":          return p.comments as Any
                case "tool":              return p.tool.rawValue as Any
                case "authMode":          return p.authMode.rawValue as Any
                case "apiKey":            return (p.apiKey ?? "") as Any
                case "closeAction":       return p.closeAction.rawValue as Any
                case "memoryGB":          return String(p.memoryGB) as Any
                case "folderPathsCount":  return String(p.folderPaths.count) as Any
                case "mcpServerCount":    return String(p.mcpServers.count) as Any
                case "keyboardLayoutOverride": return (p.keyboardLayoutOverride ?? "") as Any
                case "keyRepeatDelayMs":  return p.keyRepeatDelayMs.map { String($0) } ?? "" as Any
                case "keyRepeatRateHz":   return p.keyRepeatRateHz.map { String($0) } ?? "" as Any
                default:
                    return "error: unknown key '\(k)'" as Any
                }
            }
        case "set profile setting":
            return onMain {
                guard let d = NSApp.delegate as? ACAppDelegate else { return "error: app not ready" as Any }
                let nameOrID = directParameter as? String ?? ""
                let k = evaluatedArguments?["key"] as? String ?? ""
                let v = evaluatedArguments?["toValue"] as? String ?? ""
                guard var p = findProfile(nameOrID) else { return "error: profile not found" as Any }
                switch k {
                case "name":         p.name = v
                case "color":
                    guard let c = ProfileColor(rawValue: v) else { return "error: invalid color '\(v)'" as Any }
                    p.color = c
                case "comments":     p.comments = v
                case "tool":
                    guard let t = Profile.Tool(rawValue: v) else { return "error: invalid tool '\(v)'" as Any }
                    p.tool = t
                case "authMode":
                    guard let m = Profile.AuthMode(rawValue: v) else { return "error: invalid authMode '\(v)'" as Any }
                    p.authMode = m
                case "apiKey":       p.apiKey = v.isEmpty ? nil : v
                case "closeAction":
                    guard let a = Profile.CloseAction(rawValue: v) else { return "error: invalid closeAction '\(v)'" as Any }
                    p.closeAction = a
                case "memoryGB":
                    guard let n = Int(v), n >= 1 else { return "error: memoryGB must be a positive integer" as Any }
                    p.memoryGB = n
                case "keyboardLayoutOverride":
                    p.keyboardLayoutOverride = v.isEmpty ? nil : v
                case "keyRepeatDelayMs": p.keyRepeatDelayMs = Int(v)
                case "keyRepeatRateHz":  p.keyRepeatRateHz = Int(v)
                default:
                    return "error: unknown key '\(k)'" as Any
                }
                do {
                    try d.store.update(p)
                    d.profiles = d.store.loadAll()
                    d.applyLiveEditToRunningSession(p)   // live-apply (no reboot)
                    return "ok" as Any
                } catch {
                    return "error: \(error.localizedDescription)" as Any
                }
            }
        case "open ac session":
            return onMain {
                guard let d = NSApp.delegate as? ACAppDelegate else { return "error: app not ready" as Any }
                let key = directParameter as? String ?? ""
                guard let profile = findProfile(key) else { return "error: profile not found" as Any }
                d.launch(profile)
                return profile.id.uuidString as Any
            }
        case "close ac session":
            return onMain {
                guard let delegate = NSApp.delegate as? ACAppDelegate else { return "error: app not ready" as Any }
                let key = directParameter as? String ?? ""
                guard let profile = findProfile(key) else { return "error: profile not found" as Any }
                // Close the on-screen session for this profile (unified window or a
                // pop-out) via the close-action pipeline.
                return delegate.scriptCloseSession(profile.id) ? ("ok" as Any)
                    : ("error: no active session for profile" as Any)
            }
        case "list ac sessions":
            return onMain {
                guard let delegate = NSApp.delegate as? ACAppDelegate else { return encodeJSON([[String: Any]]()) as Any }
                // On-screen sessions only (hosted pane + visible host window),
                // spanning the unified window and any pop-outs. Detached/headless
                // VMs are "gone" from a scripting perspective, matching the prior
                // visible-window filter the e2e suite relies on.
                let arr: [[String: Any]] = delegate.scriptVisibleSessions().map { s in
                    [
                        "profileId":   s.profileID.uuidString,
                        "profileName": s.name,
                        "windowId":    s.windowID,
                        "visible":     s.visible,
                    ]
                }
                return encodeJSON(arr) as Any
            }
        case "get ac app setting":
            let key = directParameter as? String ?? ""
            guard let reader = acAppSettingDefaults[key] else {
                return "error: unknown app setting '\(key)'" as Any
            }
            return reader() as Any
        case "set ac app setting":
            return onMain {
                guard let d = NSApp.delegate as? ACAppDelegate else { return "error: app not ready" as Any }
                let key = directParameter as? String ?? ""
                let v = evaluatedArguments?["toValue"] as? String ?? ""
                let std = UserDefaults.standard

                switch key {
                case "automation.enabled":
                    let on = (v == "true" || v == "1" || v == "yes")
                    std.set(on, forKey: key)
                    if on { d.startAutomationServerIfNeeded() } else { d.stopAutomationServer() }
                case "automation.port":
                    guard let n = Int(v), n > 0, n < 65536 else { return "error: port must be in 1..65535" as Any }
                    std.set(n, forKey: key)
                case "automation.bindAddress":
                    std.set(v.isEmpty ? "127.0.0.1" : v, forKey: key)
                case "managed.serverURL", "managed.acIngestURL":
                    std.set(v, forKey: key)
                case "remoteAccess.enabled":
                    let on = (v == "true" || v == "1" || v == "yes")
                    _ = d.remoteAccessApply(["enabled": on])
                case "remoteAccess.port":
                    guard let n = Int(v), n >= 1024, n < 65536 else { return "error: port must be in 1024..65535" as Any }
                    _ = d.remoteAccessApply(["port": n])
                case "remoteAccess.bindAddress":
                    _ = d.remoteAccessApply(["bindAddress": v.isEmpty ? "0.0.0.0" : v])
                default:
                    return "error: unknown app setting '\(key)'" as Any
                }
                return "ok" as Any
            }
        default:
            return "error: unknown command '\(verb)'" as Any
        }
    }
}
