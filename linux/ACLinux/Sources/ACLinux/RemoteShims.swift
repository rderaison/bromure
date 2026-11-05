import Foundation
import NIOConcurrencyHelpers

// Stand-ins for the bits of bromure-ac the shared SSH server sources
// (_shared/RemoteAccessServer.swift, _shared/RemoteSSHHandlers.swift) reach
// for, as Sources/AgentHost/Shims.swift provides them for the agent host.

/// The terminal half of RemoteConsent (macOS: a numbered menu in the
/// attached tmux, through the automation server's pump). bromure-ac has no
/// such pump yet: no terminal counts as attached, so consent goes to the
/// fat client, or is denied when none is connected.
// partial: no terminal consent pump on Linux
// @port-skip linux-only: stand-in for ACAutomationServer's consent pump statics
enum ACAutomationServer {
    // @port-skip linux-only: stand-in
    static func isInteractivelyAttached(_ profileID: String) -> Bool { false }
    // @port-skip linux-only: stand-in
    static func presentConsentViaPump(profileID: String, prompt: String, choices: [String],
                                      timeoutSeconds: TimeInterval, token: UUID) -> Int? { nil }
    // @port-skip linux-only: stand-in
    static func withdrawConsentViaPump(token: UUID) {}
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

