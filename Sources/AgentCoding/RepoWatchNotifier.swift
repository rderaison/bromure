#if os(macOS)
import AppKit
import Foundation
import UserNotifications

// MARK: - Notifications

/// macOS notifications for the watches: a scan that found something, and
/// every new critical finding. Clicking one opens the Automations hub.
@MainActor
final class RepoWatchNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = RepoWatchNotifier()

    /// Where a click lands: the hub, on a finding when there is one.
    var onOpen: ((UUID?) -> Void)?

    private var authorized: Bool?
    private var installed = false

    /// Notifications need a real bundle (not the raw build binary).
    private var available: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    private func install() {
        guard available, !installed else { return }
        installed = true
        UNUserNotificationCenter.current().delegate = self
    }

    private func post(title: String, body: String, findingID: UUID?) {
        guard available else { return }
        install()
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let findingID { content.userInfo = ["findingID": findingID.uuidString] }
        let req = UNNotificationRequest(identifier: UUID().uuidString,
                                        content: content, trigger: nil)
        Task {
            if self.authorized == nil {
                self.authorized = (try? await center.requestAuthorization(
                    options: [.alert, .sound, .badge])) ?? false
            }
            guard self.authorized == true else { return }
            try? await center.add(req)
        }
    }

    func notifyScanFinished(watch: WatchedRepo, run: AutomationRunRecord,
                            newFindings: [RepoFinding], reported: Int) {
        guard !newFindings.isEmpty else { return }
        let worst = newFindings.sortedForTriage().first
        let title = String(format: NSLocalizedString("%1$d new finding(s) in %2$@",
                                                     comment: "scan notification title"),
                           newFindings.count, watch.repo)
        var body = worst.map { "\($0.severity.displayName): \($0.title)" } ?? ""
        if newFindings.count > 1 {
            body += "\n" + String(format: NSLocalizedString("…and %d more", comment: "scan notification"),
                                  newFindings.count - 1)
        }
        post(title: title, body: body, findingID: worst?.id)
    }

    func notifyCritical(_ f: RepoFinding) {
        post(title: String(format: NSLocalizedString("Critical finding in %@", comment: "notification title"),
                           f.repo),
             body: f.title + (f.location.isEmpty ? "" : " — " + f.location),
             findingID: f.id)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse) async {
        let id = (response.notification.request.content.userInfo["findingID"] as? String)
            .flatMap(UUID.init(uuidString:))
        await MainActor.run {
            NSApp.activate(ignoringOtherApps: true)
            self.onOpen?(id)
        }
    }
}

#endif
