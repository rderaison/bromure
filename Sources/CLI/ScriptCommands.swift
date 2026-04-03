import Cocoa
import SandboxEngine

// MARK: - Helpers

/// Run a block on the main actor. NSScriptCommand always executes on the main
/// thread, so assumeIsolated is safe here.
private func onMain<T>(_ body: @MainActor () -> T) -> T {
    MainActor.assumeIsolated { body() }
}

/// Find a profile by name (case-insensitive) or UUID string.
private func findProfile(_ nameOrID: String) -> Profile? {
    onMain {
        guard let delegate = NSApp.delegate as? GUIAppDelegate else { return nil }
        let pm = delegate.state.profileManager
        if let uuid = UUID(uuidString: nameOrID) {
            return pm.profile(withID: uuid)
        }
        return pm.allProfiles.first { $0.name.lowercased() == nameOrID.lowercased() }
    }
}

/// Read a value from ProfileSettings by key name.
private func readSetting(_ s: ProfileSettings, key: String) -> String? {
    switch key {
    case "homePage":        return s.homePage
    case "persistent":      return String(s.persistent)
    case "encryptOnDisk":   return String(s.encryptOnDisk)
    case "clipboard":       return String(s.enableClipboardSharing)
    case "gpu":             return String(s.enableGPU)
    case "webgl":           return String(s.enableWebGL)
    case "zeroCopy":        return String(s.enableZeroCopy)
    case "smoothScrolling": return String(s.enableSmoothScrolling)
    case "audio":           return String(s.enableAudio)
    case "audioVolume":     return String(s.audioVolume)
    case "webcam":          return String(s.enableWebcam)
    case "microphone":      return String(s.enableMicrophone)
    case "canUpload":       return String(s.canUpload)
    case "canDownload":     return String(s.canDownload)
    case "virusTotalEnabled": return String(s.virusTotalEnabled)
    case "virusTotalAPIKey": return s.virusTotalAPIKey ?? ""
    case "blockThreats":    return String(s.blockThreats)
    case "blockUnscannable": return String(s.blockUnscannable)
    case "blockMalware":    return String(s.blockMalwareSites)
    case "phishingWarning": return String(s.phishingWarning)
    case "linkSender":      return String(s.enableLinkSender)
    case "adBlocking":      return String(s.enableAdBlocking)
    case "warp":            return String(s.vpnMode == .cloudflareWarp)
    case "warpAutoConnect": return String(s.warpAutoConnect)
    case "isolateFromLAN":  return String(s.isolateFromLAN)
    case "restrictPorts":   return String(s.restrictPorts)
    case "allowedPorts":    return s.allowedPorts
    case "proxyHost":       return s.proxyHost
    case "proxyPort":       return String(s.proxyPort)
    case "proxyUsername":   return s.proxyUsername
    case "proxyPassword":   return s.proxyPassword
    case "ikev2Server":         return s.ikev2Server
    case "ikev2RemoteID":       return s.ikev2RemoteID
    case "ikev2AuthMethod":     return s.ikev2AuthMethod.rawValue
    case "ikev2Username":       return s.ikev2Username
    case "ikev2UseDNS":         return String(s.ikev2UseDNS)
    case "ikev2AutoConnect":    return String(s.ikev2AutoConnect)
    case "ikev2ProxyHost":      return s.ikev2ProxyHost
    case "ikev2ProxyPort":      return String(s.ikev2ProxyPort)
    case "ikev2ProxyUsername":  return s.ikev2ProxyUsername
    case "ikev2ProxyPassword":  return s.ikev2ProxyPassword
    case "allowAutomation": return String(s.allowAutomation)
    case "traceLevel":      return String(s.traceLevel.rawValue)
    case "traceAutoStart":  return String(s.traceAutoStart)
    case "matchKeyboardLayout": return String(s.matchKeyboardLayout)
    case "networkInterface": return s.networkInterface
    case "locale":          return s.locale ?? "system"
    case "webcamDeviceID":  return s.webcamDeviceID ?? ""
    case "microphoneDeviceID": return s.microphoneDeviceID ?? ""
    case "speakerDeviceID": return s.speakerDeviceID ?? ""
    default:                return nil
    }
}

/// Write a value to ProfileSettings by key name.
@discardableResult
private func writeSetting(_ s: inout ProfileSettings, key: String, value: String) -> Bool {
    let b = (value == "true" || value == "1" || value == "yes")
    switch key {
    case "homePage":        s.homePage = value
    case "persistent":      s.persistent = b
    case "encryptOnDisk":   s.encryptOnDisk = b
    case "clipboard":       s.enableClipboardSharing = b
    case "gpu":             s.enableGPU = b
    case "webgl":           s.enableWebGL = b
    case "zeroCopy":        s.enableZeroCopy = b
    case "smoothScrolling": s.enableSmoothScrolling = b
    case "audio":           s.enableAudio = b
    case "audioVolume":     s.audioVolume = Int(value) ?? s.audioVolume
    case "webcam":          s.enableWebcam = b
    case "microphone":      s.enableMicrophone = b
    case "canUpload":       s.canUpload = b
    case "canDownload":     s.canDownload = b
    case "virusTotalEnabled": s.virusTotalEnabled = b
    case "virusTotalAPIKey": s.virusTotalAPIKey = value.isEmpty ? nil : value
    case "blockThreats":    s.blockThreats = b
    case "blockUnscannable": s.blockUnscannable = b
    case "blockMalware":    s.blockMalwareSites = b
    case "phishingWarning": s.phishingWarning = b
    case "linkSender":      s.enableLinkSender = b
    case "adBlocking":      s.enableAdBlocking = b
    case "warp":            s.vpnMode = b ? .cloudflareWarp : .none
    case "warpAutoConnect": s.warpAutoConnect = b
    case "isolateFromLAN":  s.isolateFromLAN = b
    case "restrictPorts":   s.restrictPorts = b
    case "allowedPorts":    s.allowedPorts = value
    case "proxyHost":       s.proxyHost = value
    case "proxyPort":       s.proxyPort = Int(value) ?? s.proxyPort
    case "proxyUsername":   s.proxyUsername = value
    case "proxyPassword":   s.proxyPassword = value
    case "ikev2Server":         s.ikev2Server = value
    case "ikev2RemoteID":       s.ikev2RemoteID = value
    case "ikev2AuthMethod":     s.ikev2AuthMethod = IKEv2AuthMethod(rawValue: value) ?? .eap
    case "ikev2Username":       s.ikev2Username = value
    case "ikev2UseDNS":         s.ikev2UseDNS = b
    case "ikev2AutoConnect":    s.ikev2AutoConnect = b
    case "ikev2ProxyHost":      s.ikev2ProxyHost = value
    case "ikev2ProxyPort":      s.ikev2ProxyPort = Int(value) ?? s.ikev2ProxyPort
    case "ikev2ProxyUsername":  s.ikev2ProxyUsername = value
    case "ikev2ProxyPassword":  s.ikev2ProxyPassword = value
    case "vpnMode":
        if let mode = VPNMode(rawValue: value) { s.vpnMode = mode }
    case "allowAutomation": s.allowAutomation = b
    case "traceLevel":      s.traceLevel = TraceLevel(rawValue: Int(value) ?? 0) ?? .disabled
    case "traceAutoStart":  s.traceAutoStart = b
    case "matchKeyboardLayout": s.matchKeyboardLayout = b
    case "networkInterface": s.networkInterface = value
    case "locale":          s.locale = (value == "system" || value.isEmpty) ? nil : value
    case "webcamDeviceID":  s.webcamDeviceID = value.isEmpty ? nil : value
    case "microphoneDeviceID": s.microphoneDeviceID = value.isEmpty ? nil : value
    case "speakerDeviceID": s.speakerDeviceID = value.isEmpty ? nil : value
    default:                return false
    }
    return true
}

// MARK: - Profile Management Commands

@objc(BromureCreateProfileCommand)
final class CreateProfileCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        onMain {
            guard let delegate = NSApp.delegate as? GUIAppDelegate else { return "error: app not ready" as Any }
            let name = directParameter as? String ?? ""
            guard !name.isEmpty else { return "error: name required" as Any }

            let persistent = evaluatedArguments?["persistent"] as? Bool ?? false
            let colorStr = evaluatedArguments?["color"] as? String
            let homePage = evaluatedArguments?["homePage"] as? String
            let comments = evaluatedArguments?["comments"] as? String ?? ""

            var settings = ProfileSettings()
            settings.persistent = persistent
            if let hp = homePage, !hp.isEmpty { settings.homePage = hp }
            settings.enableGPU = true
            settings.enableAudio = true

            let color = colorStr.flatMap { ProfileColor(rawValue: $0) }
            let profile = delegate.state.profileManager.createProfile(
                name: name, comments: comments, color: color, settings: settings
            )
            return profile.id.uuidString as Any
        }
    }
}

@objc(BromureDeleteProfileCommand)
final class DeleteProfileCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        onMain {
            guard let delegate = NSApp.delegate as? GUIAppDelegate else { return nil }
            let nameOrID = directParameter as? String ?? ""
            guard let profile = findProfile(nameOrID) else {
                scriptErrorNumber = errOSAScriptError
                scriptErrorString = "Profile not found: \(nameOrID)"
                return nil
            }
            delegate.state.profileManager.deleteProfile(id: profile.id)
            return nil
        }
    }
}

@objc(BromureListProfilesCommand)
final class ListProfilesCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        onMain {
            guard let delegate = NSApp.delegate as? GUIAppDelegate else { return "[]" as Any }
            let profiles = delegate.state.profileManager.allProfiles.map { p -> [String: Any] in
                var d: [String: Any] = [
                    "id": p.id.uuidString,
                    "name": p.name,
                    "persistent": p.isPersistent,
                ]
                if let c = p.color { d["color"] = c.rawValue }
                if !p.comments.isEmpty { d["comments"] = p.comments }
                return d
            }
            guard let data = try? JSONSerialization.data(withJSONObject: profiles, options: [.prettyPrinted, .sortedKeys]),
                  let json = String(data: data, encoding: .utf8) else { return "[]" as Any }
            return json as Any
        }
    }
}

// MARK: - Profile Settings Commands

@objc(BromureGetProfileSettingCommand)
final class GetProfileSettingCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let nameOrID = directParameter as? String ?? ""
        let key = evaluatedArguments?["key"] as? String ?? ""
        guard let profile = findProfile(nameOrID) else {
            scriptErrorNumber = errOSAScriptError
            scriptErrorString = "Profile not found: \(nameOrID)"
            return nil
        }
        switch key {
        case "name": return profile.name
        case "color": return profile.color?.rawValue ?? "none"
        case "comments": return profile.comments
        default: break
        }
        guard let value = readSetting(profile.settings, key: key) else {
            scriptErrorNumber = errOSAScriptError
            scriptErrorString = "Unknown setting key: \(key)"
            return nil
        }
        return value
    }
}

@objc(BromureSetProfileSettingCommand)
final class SetProfileSettingCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        onMain {
            guard let delegate = NSApp.delegate as? GUIAppDelegate else { return nil }
            let nameOrID = directParameter as? String ?? ""
            let key = evaluatedArguments?["key"] as? String ?? ""
            let value = evaluatedArguments?["toValue"] as? String ?? ""
            guard var profile = findProfile(nameOrID) else {
                scriptErrorNumber = errOSAScriptError
                scriptErrorString = "Profile not found: \(nameOrID)"
                return nil
            }
            switch key {
            case "name":
                profile.name = value
                delegate.state.profileManager.updateProfile(profile)
                return nil
            case "color":
                profile.color = (value == "none" || value.isEmpty) ? nil : ProfileColor(rawValue: value)
                delegate.state.profileManager.updateProfile(profile)
                return nil
            case "comments":
                profile.comments = value
                delegate.state.profileManager.updateProfile(profile)
                return nil
            default: break
            }
            // Handle keychain-backed secrets (not stored in profile JSON)
            switch key {
            case "ikev2Secret":
                VPNKeychain.store(profileID: profile.id, key: VPNKeychain.ikev2Password, secret: value)
                return nil
            case "ikev2PSKSecret":
                VPNKeychain.store(profileID: profile.id, key: VPNKeychain.ikev2PSK, secret: value)
                return nil
            default: break
            }
            guard writeSetting(&profile.settings, key: key, value: value) else {
                scriptErrorNumber = errOSAScriptError
                scriptErrorString = "Unknown setting key: \(key)"
                return nil
            }
            delegate.state.profileManager.updateProfile(profile)
            return nil
        }
    }
}

// MARK: - App Settings Commands

@objc(BromureGetAppSettingCommand)
final class GetAppSettingCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let key = directParameter as? String ?? ""
        let d = UserDefaults.standard
        switch key {
        case "vm.memoryGB":       return String(d.integer(forKey: key))
        case "vm.cpuCount":       return String(d.integer(forKey: key))
        case "vm.keyboardLayout": return d.string(forKey: key) ?? VMConfig.detectKeyboardLayout()
        case "vm.naturalScrolling":
            return String(d.object(forKey: key) as? Bool ?? VMConfig.detectNaturalScrolling())
        case "vm.swapCmdCtrl":
            return String(d.object(forKey: key) as? Bool ?? true)
        case "vm.displayScale":
            return String(d.object(forKey: key) as? Int ?? VMConfig.detectDisplayScale())
        case "vm.appearance":     return d.string(forKey: key) ?? "system"
        case "vm.networkMode":    return d.string(forKey: key) ?? "nat"
        case "vm.bridgedInterface": return d.string(forKey: key) ?? ""
        case "vm.dnsServers":     return d.string(forKey: key) ?? ""
        case "automation.enabled": return String(d.bool(forKey: key))
        case "automation.port":   return String(d.integer(forKey: key))
        case "automation.bindAddress": return d.string(forKey: key) ?? "127.0.0.1"
        default:
            scriptErrorNumber = errOSAScriptError
            scriptErrorString = "Unknown app setting: \(key)"
            return nil
        }
    }
}

@objc(BromureSetAppSettingCommand)
final class SetAppSettingCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        onMain {
            let key = directParameter as? String ?? ""
            let value = evaluatedArguments?["toValue"] as? String ?? ""
            let d = UserDefaults.standard
            let b = (value == "true" || value == "1" || value == "yes")

            // Capture old value for pool-restart comparison
            let oldValue = d.object(forKey: key).map { "\($0)" }

            switch key {
            case "vm.memoryGB":         d.set(Int(value) ?? 0, forKey: key)
            case "vm.cpuCount":         d.set(Int(value) ?? 0, forKey: key)
            case "vm.keyboardLayout":   d.set(value, forKey: key)
            case "vm.naturalScrolling": d.set(b, forKey: key)
            case "vm.swapCmdCtrl":      d.set(b, forKey: key)
            case "vm.displayScale":     d.set(Int(value) ?? 2, forKey: key)
            case "vm.appearance":       d.set(value, forKey: key)
            case "vm.networkMode":      d.set(value, forKey: key)
            case "vm.bridgedInterface": d.set(value, forKey: key)
            case "vm.dnsServers":       d.set(value, forKey: key)
            case "automation.enabled":  d.set(b, forKey: key)
            case "automation.port":     d.set(Int(value) ?? 9222, forKey: key)
            case "automation.bindAddress": d.set(value, forKey: key)
            default:
                scriptErrorNumber = errOSAScriptError
                scriptErrorString = "Unknown app setting: \(key)"
                return nil
            }

            // Only restart the pool for settings that affect VM hardware config.
            // vm.appearance and vm.swapCmdCtrl are applied at claim time and don't
            // need a pool restart.
            let poolKeys = ["vm.memoryGB", "vm.cpuCount",
                            "vm.networkMode", "vm.bridgedInterface", "vm.dnsServers"]
            if poolKeys.contains(key), oldValue != value {
                if let delegate = NSApp.delegate as? GUIAppDelegate {
                    delegate.state.restartPool()
                    // Offer to restart active sessions
                    if !delegate.sessions.isEmpty {
                        let alert = NSAlert()
                        alert.messageText = NSLocalizedString("Restart sessions?", comment: "")
                        alert.informativeText = NSLocalizedString("Hardware settings have changed. Restart all browser sessions to apply them?", comment: "")
                        alert.addButton(withTitle: NSLocalizedString("Restart All", comment: ""))
                        alert.addButton(withTitle: NSLocalizedString("Later", comment: ""))
                        if alert.runModal() == .alertFirstButtonReturn {
                            let sessions = delegate.sessions
                            Task { @MainActor in
                                for session in sessions {
                                    if let profile = session.profile {
                                        await delegate.restartSession(session, profile: profile)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            if key == "automation.enabled" {
                if b {
                    (NSApp.delegate as? GUIAppDelegate)?.startAutomationServerIfNeeded()
                } else {
                    (NSApp.delegate as? GUIAppDelegate)?.stopAutomationServer()
                }
            }
            return nil
        }
    }
}

// MARK: - Session Actions

@objc(BromureToggleWarpCommand)
final class ToggleWarpCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        onMain {
            guard let delegate = NSApp.delegate as? GUIAppDelegate else { return nil }
            let sessionID = directParameter as? String ?? ""
            guard let session = delegate.sessions.first(where: { $0.id.uuidString == sessionID }) else {
                scriptErrorNumber = errOSAScriptError
                scriptErrorString = "Session not found: \(sessionID)"
                return nil
            }
            session.toggleWarp()
            return nil
        }
    }
}

// MARK: - Profile Settings Command

@objc(BromureOpenProfileSettingsCommand)
final class OpenProfileSettingsCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        onMain {
            guard let delegate = NSApp.delegate as? GUIAppDelegate else { return nil }
            let nameOrID = directParameter as? String ?? ""
            guard let profile = findProfile(nameOrID) else {
                scriptErrorNumber = errOSAScriptError
                scriptErrorString = "Profile not found: \(nameOrID)"
                return nil
            }
            let category = evaluatedArguments?["category"] as? String
            delegate.state.onOpenProfileSettings?(profile.id, category)
            return nil
        }
    }
}

// MARK: - Trace Recording Control

@objc(BromureToggleTraceCommand)
final class ToggleTraceCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        onMain {
            guard let delegate = NSApp.delegate as? GUIAppDelegate else { return nil }
            let sessionID = directParameter as? String ?? ""
            guard let session = delegate.sessions.first(where: { $0.id.uuidString == sessionID }) else {
                scriptErrorNumber = errOSAScriptError
                scriptErrorString = "Session not found: \(sessionID)"
                return nil
            }
            session.toggleTraceRecording()
            return nil
        }
    }
}

// MARK: - Trace Command

@objc(BromureGetTraceCommand)
final class GetTraceCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        onMain {
            guard let delegate = NSApp.delegate as? GUIAppDelegate else { return "[]" as Any }
            let sessionID = directParameter as? String ?? ""
            guard let session = delegate.sessions.first(where: { $0.id.uuidString == sessionID }),
                  let bridge = session.traceBridge else {
                return "[]" as Any
            }
            let data = bridge.exportAsJSON()
            guard let json = String(data: data, encoding: .utf8) else { return "[]" as Any }
            return json as Any
        }
    }
}

// MARK: - App State Command

@objc(BromureGetAppStateCommand)
final class GetAppStateCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        onMain {
            guard let delegate = NSApp.delegate as? GUIAppDelegate else { return "{}" as Any }
            let state = delegate.state

            let phase: String
            switch state.phase {
            case .checking: phase = "checking"
            case .needsSetup: phase = "needsSetup"
            case .initializing(let status, _): phase = "initializing: \(status)"
            case .warmingUp: phase = "warmingUp"
            case .ready: phase = "ready"
            case .error(let msg): phase = "error: \(msg)"
            }

            let sessions = delegate.sessions.map { s -> [String: Any] in
                ["id": s.id.uuidString]
            }

            let result: [String: Any] = [
                "phase": phase,
                "poolReady": state.poolReady,
                "sessionCount": state.sessionCount,
                "sessions": sessions,
                "profiles": state.profileManager.allProfiles.map { ["id": $0.id.uuidString, "name": $0.name] },
            ]

            guard let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]),
                  let json = String(data: data, encoding: .utf8) else { return "{}" as Any }
            return json as Any
        }
    }
}
