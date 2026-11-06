import Foundation
import Observation
import SwiftUI

/// Whether a guest still proves it can run a process. agentd spawns one about
/// once a minute and rewrites `liveness.txt` only if that worked, so a kernel
/// that has wedged and a guest too short of memory to fork look the same from
/// here: the file stops changing. (`vmstat.txt` can't say this: agentd's own
/// loop can keep reading /proc on a guest that can't start anything, and the
/// host re-reads the last copy after the guest has stopped altogether.)
///
/// Only ever a report. A guest out of memory can come back when the OOM killer
/// has done its work, so what to do about one stays the user's call.
struct GuestLiveness {
    /// Two missed beats and a bit, so one slow spawn or a late poll is no alarm.
    static let patience: TimeInterval = 150

    private var lastBeat: String?
    private var lastBeatAt: TimeInterval?

    /// Whether the guest has gone silent, given the file's contents now. A
    /// guest that has never beaten (an older agentd, one still booting) is never
    /// silent, and a VM not running (paused, suspending) isn't expected to beat.
    /// `now` must not advance while the Mac sleeps: `ProcessInfo.systemUptime`.
    mutating func observe(_ beat: String?, running: Bool, now: TimeInterval) -> Bool {
        if let beat, !beat.isEmpty, beat != lastBeat {
            lastBeat = beat
            lastBeatAt = now
        }
        guard let at = lastBeatAt else { return false }
        guard running else {
            lastBeatAt = now
            return false
        }
        return now - at >= Self.patience
    }
}

/// The workspaces whose guest has gone silent, from this Mac's VMs and from a
/// fat client's server alike, each with how to force-reboot it from here.
@MainActor
@Observable
final class GuestLivenessStore {
    static let shared = GuestLivenessStore()

    private var forceReboots: [Profile.ID: @MainActor () -> Void] = [:]

    func isUnresponsive(_ id: Profile.ID) -> Bool { forceReboots[id] != nil }
    func forceReboot(of id: Profile.ID) -> (@MainActor () -> Void)? { forceReboots[id] }

    func mark(_ id: Profile.ID, unresponsive: Bool, forceReboot: @escaping @MainActor () -> Void) {
        if unresponsive {
            forceReboots[id] = forceReboot   // the latest reporter is the one alive
        } else {
            clear(id)
        }
    }

    func clear(_ id: Profile.ID) {
        if forceReboots[id] != nil { forceReboots[id] = nil }
    }
}

/// Over a chat whose guest has gone silent: what's on screen may be old.
/// Its own view, so the transcript around it doesn't read the store.
struct GuestUnresponsiveBanner: View {
    let profileID: Profile.ID?

    var body: some View {
        if let profileID, let forceReboot = GuestLivenessStore.shared.forceReboot(of: profileID) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text(NSLocalizedString("This workspace isn't responding", comment: "beautified: the guest has gone silent"))
                        .font(.system(size: 12, weight: .semibold))
                    Text(NSLocalizedString("It may be out of memory. What's shown here may be out of date.", comment: "beautified: the guest has gone silent"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button(NSLocalizedString("Force Reboot", comment: "reboot")) { forceReboot() }
                    .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10).fill(.regularMaterial))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
            .shadow(color: .black.opacity(0.10), radius: 6, y: 2)
            .padding(.horizontal, 14)
            .padding(.top, 8)
        }
    }
}
