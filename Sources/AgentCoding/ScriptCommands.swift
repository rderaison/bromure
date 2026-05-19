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
        onMain {
            let d = NSApp.delegate as? ACAppDelegate
            let state: [String: Any] = [
                "locale":          (UserDefaults.standard.array(forKey: "AppleLanguages") as? [String])?.first ?? "system",
                "mainWindowOpen":  (d?.mainWindow?.isVisible ?? false) as Any,
                "editorOpen":      (d?.editorWindow?.isVisible ?? false) as Any,
                "profileCount":    d?.profiles.count ?? 0,
            ]
            return encodeJSON(state) as Any
        }
    }
}

@objc(BromureACListProfilesCommand)
final class BromureACListProfilesCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        onMain {
            guard let d = NSApp.delegate as? ACAppDelegate else { return "[]" as Any }
            let arr: [[String: Any]] = d.profiles.map {
                ["id": $0.id.uuidString,
                 "name": $0.name,
                 "color": $0.color.rawValue]
            }
            return encodeJSON(arr) as Any
        }
    }
}

// MARK: - Profile management

@objc(BromureACCreateProfileCommand)
final class BromureACCreateProfileCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        onMain {
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
    }
}

@objc(BromureACDeleteProfileCommand)
final class BromureACDeleteProfileCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        onMain {
            guard let d = NSApp.delegate as? ACAppDelegate else { return "error: app not ready" as Any }
            let key = directParameter as? String ?? ""
            guard let profile = findProfile(key) else { return "error: profile not found" as Any }
            try? d.store.delete(profile)
            d.profiles = d.store.loadAll()
            return "ok" as Any
        }
    }
}

// MARK: - Window navigation

@objc(BromureACOpenProfileManagerCommand)
final class BromureACOpenProfileManagerCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        onMain {
            (NSApp.delegate as? ACAppDelegate)?.openProfileManagerAction(nil)
            return "ok" as Any
        }
    }
}

@objc(BromureACOpenProfileEditorCommand)
final class BromureACOpenProfileEditorCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        onMain {
            guard let d = NSApp.delegate as? ACAppDelegate else { return "error: app not ready" as Any }
            let key = directParameter as? String ?? ""
            guard let profile = findProfile(key) else { return "error: profile not found" as Any }
            d.openEditorWindow(editing: profile)
            return "ok" as Any
        }
    }
}

@objc(BromureACCloseProfileEditorCommand)
final class BromureACCloseProfileEditorCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        onMain {
            (NSApp.delegate as? ACAppDelegate)?.closeEditorWindow()
            return "ok" as Any
        }
    }
}

@objc(BromureACSelectEditorCategoryCommand)
final class BromureACSelectEditorCategoryCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let raw = (directParameter as? String ?? "").lowercased()
        guard !raw.isEmpty else { return "error: category required" as Any }
        // The editor view subscribes to this notification and updates
        // its selectedCategory @State on receipt.
        NotificationCenter.default.post(
            name: .bromureACSelectEditorCategory, object: raw)
        return "ok" as Any
    }
}

@objc(BromureACGetEditorWindowIDCommand)
final class BromureACGetEditorWindowIDCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        onMain {
            let id = (NSApp.delegate as? ACAppDelegate)?.editorWindow?.windowNumber ?? 0
            return id as Any
        }
    }
}

@objc(BromureACGetMainWindowIDCommand)
final class BromureACGetMainWindowIDCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        onMain {
            let id = (NSApp.delegate as? ACAppDelegate)?.mainWindow?.windowNumber ?? 0
            return id as Any
        }
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
// this bridge (it's a debug surface), so callers should treat the
// blob as sensitive.

@objc(BromureACGetProfileJSONCommand)
final class BromureACGetProfileJSONCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        onMain {
            guard let key = directParameter as? String, !key.isEmpty else {
                return "error: profile name or UUID required" as Any
            }
            guard let profile = findProfile(key) else { return "error: profile not found" as Any }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(profile),
                  let str = String(data: data, encoding: .utf8) else {
                return "error: encode failed" as Any
            }
            return str as Any
        }
    }
}

@objc(BromureACSetProfileJSONCommand)
final class BromureACSetProfileJSONCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        onMain {
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
                try d.store.save(incoming)
                d.profiles = d.store.loadAll()
                return "ok" as Any
            } catch {
                return "error: \(error.localizedDescription)" as Any
            }
        }
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
        onMain {
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
    }
}

@objc(BromureACSetProfileSettingCommand)
final class BromureACSetProfileSettingCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        onMain {
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
                try d.store.save(p)
                d.profiles = d.store.loadAll()
                return "ok" as Any
            } catch {
                return "error: \(error.localizedDescription)" as Any
            }
        }
    }
}

// MARK: - Session control

@objc(BromureACOpenSessionCommand)
final class BromureACOpenSessionCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        onMain {
            guard let d = NSApp.delegate as? ACAppDelegate else { return "error: app not ready" as Any }
            let key = directParameter as? String ?? ""
            guard let profile = findProfile(key) else { return "error: profile not found" as Any }
            d.launch(profile)
            return profile.id.uuidString as Any
        }
    }
}

@objc(BromureACCloseSessionCommand)
final class BromureACCloseSessionCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        onMain {
            guard NSApp.delegate is ACAppDelegate else { return "error: app not ready" as Any }
            let key = directParameter as? String ?? ""
            guard let profile = findProfile(key) else { return "error: profile not found" as Any }
            // Find the open session window for this profile and close it.
            for win in NSApp.windows {
                if let session = win as? TabbedSessionWindow, session.profile.id == profile.id {
                    session.performClose(nil)
                    return "ok" as Any
                }
            }
            return "error: no active session for profile" as Any
        }
    }
}

@objc(BromureACListSessionsCommand)
final class BromureACListSessionsCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        onMain {
            let sessions = NSApp.windows.compactMap { $0 as? TabbedSessionWindow }
            let arr: [[String: Any]] = sessions.map { s in
                [
                    "profileId":   s.profile.id.uuidString,
                    "profileName": s.profile.name,
                    "windowId":    s.windowNumber,
                    "visible":     s.isVisible,
                ]
            }
            return encodeJSON(arr) as Any
        }
    }
}
