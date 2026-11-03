import Foundation
import NIOConcurrencyHelpers

// Stand-ins for the bits of bromure-ac the shared SSH server sources
// (_shared/RemoteAccessServer.swift, _shared/RemoteSSHHandlers.swift) reach
// for, as Sources/AgentHost/Shims.swift provides them for the agent host.

/// The server's audit breadcrumbs go to the daemon's log.
// @port-skip linux-only: stand-in for the macOS MITM supply-chain log
final class SupplyChainLog: Sendable {
    static let shared = SupplyChainLog()
    // @port-skip linux-only: stand-in
    func record(_ line: String) { FileHandle.standardError.write(Data("bromure-ac daemon: \(line)\n".utf8)) }
}

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
}
