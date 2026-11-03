import Foundation
#if canImport(Darwin)
import Darwin
#endif
import ServiceManagement

// MARK: - Why the network helper can't be reached

/// "The privileged network helper isn't reachable" said nothing about why,
/// while Login Items showed it enabled. This gathers what can be seen from the
/// app (no root): the registration, the socket, the connect error, and
/// launchd's view of the job -- and names the likely cause.
enum FatClientTunnelDiagnosis {
    static let launchdLabel = "io.bromure.fatclient-tunnel"

    /// The helper's socket as seen from here; nil when it doesn't exist.
    struct SocketInfo: Equatable {
        var ownerUID: uid_t
        var mode: mode_t
    }

    /// The parts of `launchctl print system/<label>` that say why it isn't up.
    struct LaunchdInfo: Equatable {
        var state: String?
        var program: String?
        var lastExit: String?
        var pid: String?
    }

    static func socketInfo(_ path: String = FatClientTunnelDaemon.socketPath) -> SocketInfo? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return SocketInfo(ownerUID: st.st_uid, mode: st.st_mode & 0o777)
    }

    static func parseLaunchctl(_ text: String) -> LaunchdInfo? {
        guard !text.contains("Could not find service") else { return nil }
        var info = LaunchdInfo()
        // The job's own keys are one tab deep; nested dictionaries go deeper.
        for raw in text.split(separator: "\n") where raw.hasPrefix("\t") && !raw.hasPrefix("\t\t") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let eq = line.range(of: " = ") else { continue }
            let key = String(line[..<eq.lowerBound]), value = String(line[eq.upperBound...])
            switch key {
            case "state": info.state = value
            case "program": info.program = value
            case "last exit code": info.lastExit = value
            case "pid": info.pid = value
            default: break
            }
        }
        return info == LaunchdInfo() ? nil : info
    }

    /// launchd's view of the job, read as the user (no root needed).
    static func launchdInfo() -> LaunchdInfo? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["print", "system/\(launchdLabel)"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return parseLaunchctl(String(decoding: data, as: UTF8.self))
    }

    static func registrationName(_ status: SMAppService.Status) -> String {
        switch status {
        case .enabled: return "enabled"
        case .requiresApproval: return "waiting for approval"
        case .notRegistered: return "not registered"
        case .notFound: return "not found in the app"
        @unknown default: return "status \(status.rawValue)"
        }
    }

    /// Why connecting to the helper's socket failed, for the alert: the likely
    /// cause first, then what was seen.
    static func explainConnectFailure(errno err: Int32, socket: SocketInfo?, myUID: uid_t,
                                      launchd: LaunchdInfo?, registration: String,
                                      bundlePath: String = Bundle.main.bundlePath) -> String {
        var cause: String
        if let s = socket, err == EACCES || err == EPERM, s.ownerUID != myUID, s.mode & 0o006 != 0o006 {
            cause = String(format: NSLocalizedString(
                "The helper is running, but its socket only lets user %d in, not you (%d). Older versions of the helper hand the socket to whoever is logged in when it starts — and it starts at boot, before anyone logs in. Restart it: in System Settings › General › Login Items, turn “Bromure Agentic Coding” off and on again (or restart the Mac once this version is installed).",
                comment: "tunnel diagnosis: socket owned by another user"), Int(s.ownerUID), Int(myUID))
        } else if socket == nil || err == ENOENT {
            if let program = launchd?.program, !program.hasPrefix(bundlePath) {
                cause = String(format: NSLocalizedString(
                    "The helper isn't running. macOS has it registered from another copy of the app (%@) — it was approved there, and that copy was moved, replaced or deleted. Turn “Bromure Agentic Coding” off in Login Items, then turn the tunnel on again here to register this copy.",
                    comment: "tunnel diagnosis: daemon registered from another app path"), program)
            } else if let exit = launchd?.lastExit, exit != "(never exited)", exit != "0" {
                cause = String(format: NSLocalizedString(
                    "The helper isn't running: macOS starts it and it stops right away (last exit: %@). This usually means the app was rebuilt or updated with a different signature than the one you approved. Turn “Bromure Agentic Coding” off and on again in Login Items.",
                    comment: "tunnel diagnosis: daemon keeps exiting"), exit)
            } else if launchd == nil {
                cause = NSLocalizedString(
                    "The helper isn't loaded in launchd, although Login Items shows it. Turn “Bromure Agentic Coding” off and on again in Login Items.",
                    comment: "tunnel diagnosis: daemon not loaded")
            } else {
                cause = NSLocalizedString(
                    "The helper isn't running yet, so its socket isn't there.",
                    comment: "tunnel diagnosis: daemon not running")
            }
        } else if err == ECONNREFUSED {
            cause = NSLocalizedString(
                "The helper's socket is there but nobody answers: the helper stopped. Turn “Bromure Agentic Coding” off and on again in Login Items.",
                comment: "tunnel diagnosis: stale socket")
        } else {
            cause = NSLocalizedString("The helper didn't accept the connection.",
                                      comment: "tunnel diagnosis: other connect error")
        }
        var facts = ["registration: \(registration)",
                     "connect: \(String(cString: strerror(err))) (errno \(err))"]
        if let s = socket {
            facts.append("socket: owner uid \(s.ownerUID), mode \(String(s.mode, radix: 8)) (you are uid \(myUID))")
        } else {
            facts.append("socket: \(FatClientTunnelDaemon.socketPath) missing")
        }
        if let l = launchd {
            facts.append("launchd: " + [l.state.map { "state \($0)" }, l.pid.map { "pid \($0)" },
                                        l.lastExit.map { "last exit \($0)" }, l.program.map { "program \($0)" }]
                .compactMap { $0 }.joined(separator: ", "))
        } else {
            facts.append("launchd: system/\(launchdLabel) not loaded")
        }
        return cause + "\n\n" + facts.joined(separator: "\n")
    }

    /// The helper's `ERR …` reply to SETUP, for the alert.
    static func explainSetupError(_ reply: String?, cidr: String) -> String {
        let detail = (reply ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard detail.hasPrefix("ERR ") else {
            return NSLocalizedString(
                "The network helper closed the connection without an answer. If you just updated the app, restart the helper: turn “Bromure Agentic Coding” off and on again in Login Items.",
                comment: "tunnel diagnosis: no reply to SETUP")
        }
        let why = String(detail.dropFirst(4))
        if why.hasPrefix("route taken")
            || (why.hasPrefix("route ") && why.localizedCaseInsensitiveContains("File exists")) {
            return String(format: NSLocalizedString(
                "This Mac already routes %@ somewhere else — usually its own workspaces, which use the same subnet as the remote's. The tunnel can't take it over.\n\nHelper: %@",
                comment: "tunnel diagnosis: route exists"), cidr, why)
        }
        if why.hasPrefix("cidr ") {
            return String(format: NSLocalizedString(
                "The network helper only routes a private /24 network (in 10/8, 172.16/12, 192.168/16 or 100.64/10), and the remote's subnet %@ isn't one.\n\nHelper: %@",
                comment: "tunnel diagnosis: subnet refused"), cidr, why)
        }
        if why.hasPrefix("unsigned") {
            return String(format: NSLocalizedString(
                "The network helper only serves the copy of Bromure Agentic Coding it was installed from, signed the same way. If you just updated or rebuilt the app, restart the helper: turn “Bromure Agentic Coding” off and on again in Login Items.\n\nHelper: %@",
                comment: "tunnel diagnosis: caller not signed like the helper"), why)
        }
        if why.hasPrefix("busy") {
            return String(format: NSLocalizedString(
                "The network helper already holds %d tunnels, its limit. Close the window of a remote you aren't using, or quit and reopen the app.\n\nHelper: %@",
                comment: "tunnel diagnosis: too many tunnels"), FatClientTunnelDaemon.maxTunnels, why)
        }
        if why.hasPrefix("denied") {
            return String(format: NSLocalizedString(
                "The network helper only serves the user logged in at the screen.\n\nHelper: %@",
                comment: "tunnel diagnosis: peer denied"), why)
        }
        return String(format: NSLocalizedString(
            "The network helper couldn't create the tunnel interface.\n\nHelper: %@",
            comment: "tunnel diagnosis: setup failed"), why)
    }
}
