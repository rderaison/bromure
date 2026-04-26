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
