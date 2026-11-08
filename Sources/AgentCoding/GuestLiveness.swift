import Foundation
import Observation
import SwiftUI

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
