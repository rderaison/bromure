import Foundation
import NIOConcurrencyHelpers

// Stand-ins for the bits of bromure-ac the shared SSH server sources
// (_shared/RemoteAccessServer.swift, _shared/RemoteSSHHandlers.swift) reach
// for, as Sources/AgentHost/Shims.swift provides them for the agent host.

/// ACAutomationServer's statics shared code reaches for. The terminal
/// consent gate is the shared one (_shared/PumpConsentGate.swift, an
/// extension of this type); the daemon's interactive exec registers it
/// (Daemon.interactiveExec).
// @port-skip linux-only: stand-in for ACAutomationServer (the automation server is the daemon here)
enum ACAutomationServer {
    /// Something /state shows changed (MachineLinks): the daemon's push
    /// compares each snapshot with the last itself, so there's nothing to
    /// note.
    // @port-skip linux-only: stand-in (stateSubscribe diffs snapshots)
    static func noteMutation() {}
}

// Darwin's spellings in the shared socket code (MachineLinks.swift), on
// Glibc: SO_NOSIGPIPE doesn't exist (the daemon ignores SIGPIPE: see
// BromureAC.swift, and setsockopt refuses the option, ENOPROTOOPT),
// shutdown's `how` is the Int SHUT_* are, and timeval's microseconds are
// an Int.

/// No such socket option on Linux: setsockopt fails with ENOPROTOOPT.
// @port-skip linux-only: Darwin's constant for shared code (SIGPIPE is ignored process-wide)
let SO_NOSIGPIPE: Int32 = 0x7FFF_0000

/// shutdown(2) with Glibc's Int SHUT_RD / SHUT_WR / SHUT_RDWR.
// @port-skip linux-only: Darwin's shutdown signature for shared code
@discardableResult
func shutdown(_ fd: Int32, _ how: Int) -> Int32 { Glibc.shutdown(fd, Int32(how)) }

extension timeval {
    /// Darwin's timeval(tv_sec:tv_usec:) with an Int32 microseconds.
    // @port-skip linux-only: Darwin's timeval initializer for shared code
    init(tv_sec: Int, tv_usec: Int32) { self.init(tv_sec: tv_sec, tv_usec: Int(tv_usec)) }
}

/// The SessionDisk constants shared code names, from GuestPorts (macOS:
/// SessionDisk.swift, the per-session disk and its VZ devices, which Linux
/// does its own way: HomeSeed, the daemon).
// @port-skip linux-only: stand-in for SessionDisk's port constants (forwarding to GuestPorts, like SessionDisk)
enum SessionDisk {
    static let guestProxyPort = GuestPorts.guestProxyPort
    static let legacyGuestProxyPort = GuestPorts.legacyGuestProxyPort
    static let browserMCPVsockPort = GuestPorts.browserMCPVsockPort
    static let taskBoardMCPVsockPort = GuestPorts.taskBoardMCPVsockPort
    static let planStreamVsockPort = GuestPorts.planStreamVsockPort
    static let automationMCPVsockPort = GuestPorts.automationMCPVsockPort
    static let kubeMCPVsockPort = GuestPorts.kubeMCPVsockPort
    static let delegationMCPVsockPort = GuestPorts.delegationMCPVsockPort
    static let switchboardMCPVsockPort = GuestPorts.switchboardMCPVsockPort
    static let switchboardMCPShimGuestPath = GuestMetaPaths.switchboardMCPShimGuestPath
    static let switchboardMCPConfigGuestPath = GuestMetaPaths.switchboardMCPConfigGuestPath
    static let outboxURLRelayFolder = GuestOutboxPaths.urlRelayFolder
    static let outboxAgentFolder = GuestOutboxPaths.agentFolder
    /// The guest hostname a workspace's name gives (the daemon's port of it).
    // @port-skip linux-only: forwards to Daemon.sanitizeHostname (the port of SessionDisk.sanitizeHostname)
    static func sanitizeHostname(_ name: String) -> String { Daemon.sanitizeHostname(name) }
}


/// The app's durable log (macOS: AppLog, a copy of the GUI process's stderr
/// in ~/Library/Logs). The daemon's stderr is the journal already: a stamp
/// is a line there.
// @port-skip linux-only: stand-in for AppLog (Darwin/MachO-bound)
enum AppLog {
    // partial: a line on stderr (the journal), no date/file
    // @port AppLog.static stamp(_: String, alsoToTerminal: Bool) h=ebe2401992b47f7d @df9e60bd
    static func stamp(_ text: String, alsoToTerminal: Bool = false) {
        FileHandle.standardError.write(Data("=== \(text)\n".utf8))
    }
}

/// FDGuard's pass-through behaviour (macOS: FDGuard.swift, its audit armed
/// only by env, on Darwin's guarded-fd syscall and os.Logger): adopt and
/// disown are no-ops, close is close(2).
// @port-skip linux-only: stand-in for FDGuard (Darwin guarded fds, os.Logger)
enum FDGuard {
    // partial: no-op stand-in
    // @port FDGuard.static adopt(_: Int32, _: String) h=b1d5b9a767b718c7 @55adf953
    static func adopt(_ fd: Int32, _ owner: String) {}
    // partial: no-op stand-in
    // @port FDGuard.static disown(_: Int32, _: String) h=ccfebf39477fe3b1 @55adf953
    static func disown(_ fd: Int32, _ owner: String) {}
    // partial: plain close(2)
    // @port FDGuard.static close(_: Int32, _: String) h=a455076ea46215a0 @55adf953
    @discardableResult
    static func close(_ fd: Int32, _ owner: String) -> Int32 { fdClose(fd) }
}

/// TranscriptSearchIndex (macOS: a Mac's own searchable copy of every
/// session's conversation, for its sidebar search and previews; macOS-only).
/// A Linux server keeps none (a fat client searches its own mirror), so a
/// session leaving the store has no saved copy to forget.
// @port-skip linux-only: stand-in for TranscriptSearchIndex (macOS-only: the app's sidebar search)
@MainActor
final class TranscriptSearchIndex {
    static let shared = TranscriptSearchIndex()
    // @port-skip linux-only: stand-in (nothing is saved on Linux)
    func forget(_ id: UUID) {}
}
