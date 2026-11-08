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
}


/// The app's durable log (macOS: AppLog, a copy of the GUI process's stderr
/// in ~/Library/Logs). The daemon's stderr is the journal already: a stamp
/// is a line there.
// @port-skip linux-only: stand-in for AppLog (Darwin/MachO-bound)
enum AppLog {
    // @port-skip linux-only: see AppLog
    static func stamp(_ text: String, alsoToTerminal: Bool = false) {
        FileHandle.standardError.write(Data("=== \(text)\n".utf8))
    }
}

/// FDGuard's pass-through behaviour (macOS: FDGuard.swift, its audit armed
/// only by env, on Darwin's guarded-fd syscall and os.Logger): adopt and
/// disown are no-ops, close is close(2).
// @port-skip linux-only: stand-in for FDGuard (Darwin guarded fds, os.Logger)
enum FDGuard {
    // @port-skip linux-only: stand-in for FDGuard
    static func adopt(_ fd: Int32, _ owner: String) {}
    // @port-skip linux-only: stand-in for FDGuard
    static func disown(_ fd: Int32, _ owner: String) {}
    // @port-skip linux-only: stand-in for FDGuard
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
