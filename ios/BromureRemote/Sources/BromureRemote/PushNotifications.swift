import SwiftUI
import UIKit
import UserNotifications

// MARK: - Push notifications (iOS)
//
// A backgrounded app can't hold its mirror connection, so a coding agent that
// needs input is delivered by APNs (see bromure-infra's push-dispatch worker).
// This owns the phone half: register the APNs token with the account, withdraw
// a notification when a silent "clear" push says the question was answered, and
// reconcile on foreground so no stale "needs input" card ever survives.

/// Where a tapped notification wants to take us: a server + its workspace window.
struct PushTapTarget: Equatable {
    let serverInstallId: String
    let profileId: String?
    let windowIndex: Int?
}

@MainActor
@Observable
final class PushManager {
    static let shared = PushManager()

    /// Set when a notification is tapped; RootView routes to it and clears it.
    var tapTarget: PushTapTarget?

    /// Latest APNs token (hex), kept so we can (re)register after sign-in.
    private var apnsTokenHex: String?

    private var environment: String {
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }

    // MARK: Token registration

    func registerAPNsToken(_ deviceToken: Data) {
        apnsTokenHex = deviceToken.map { String(format: "%02x", $0) }.joined()
        syncToken()
    }

    /// POST the stored token to the account. Safe to call repeatedly — e.g. on
    /// launch, and again once the user signs in to bromure.io.
    func syncToken() {
        guard let token = apnsTokenHex, let (client, bearer) = ControlPlaneClient.current() else { return }
        let env = environment
        let bundle = Bundle.main.bundleIdentifier ?? "io.bromure.remote"
        let pushPubkey = PushKeypair.publicKeyHex
        Task {
            try? await client.registerPushToken(bearer: bearer, token: token,
                                                 environment: env, bundleId: bundle)
            // Publish this device's X25519 key so the Mac can E2E-seal to it.
            if let pushPubkey {
                try? await client.registerPushKey(bearer: bearer, pubkeyHex: pushPubkey)
            }
        }
    }

    // MARK: Incoming

    /// A silent "clear" push: the question was answered — withdraw its card.
    func handleClear(_ userInfo: [AnyHashable: Any]) {
        guard let event = userInfo["clear"] as? String ?? userInfo["event"] as? String else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [event])
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [event])
    }

    /// A tapped notification: route to the workspace window that's waiting.
    func handleTap(_ userInfo: [AnyHashable: Any]) {
        guard let server = userInfo["server"] as? String else { return }
        let window = userInfo["window"] as? Int
            ?? (userInfo["window"] as? String).flatMap(Int.init)
        tapTarget = PushTapTarget(serverInstallId: server,
                                  profileId: userInfo["profile"] as? String,
                                  windowIndex: window)
    }

    // MARK: Reconciliation (the guarantee)

    /// Remove any delivered notification whose question is no longer pending on
    /// the account. Runs on foreground, so a silent clear that iOS dropped can't
    /// leave a stale card. The delivered notification's identifier is the event
    /// key (we set apns-collapse-id = event key).
    func reconcile() {
        guard let (client, bearer) = ControlPlaneClient.current() else { return }
        Task {
            let live: Set<String>
            do { live = Set(try await client.pendingNotifications(bearer: bearer).map(\.eventKey)) }
            catch { return }
            let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
            let stale = delivered.map(\.request.identifier).filter { !live.contains($0) }
            if !stale.isEmpty {
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: stale)
            }
        }
    }
}

// MARK: - App delegate (APNs plumbing)

/// SwiftUI's App can't receive the UIKit APNs callbacks, so a thin delegate
/// bridges them into `PushManager`. Wired via `@UIApplicationDelegateAdaptor`.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        // Alert/badge/sound auth is requested elsewhere (AppBadge); the APNs
        // registration only needs the token, so kick it off regardless.
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in PushManager.shared.registerAPNsToken(deviceToken) }
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NSLog("[push] APNs registration failed: %@", error.localizedDescription)
    }

    // Silent "clear" pushes (content-available) land here in the background.
    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async
        -> UIBackgroundFetchResult {
        await MainActor.run { PushManager.shared.handleClear(userInfo) }
        return .noData
    }

    // Foreground presentation — still show it (the user may not be in that VM).
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    // A tap.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        await MainActor.run {
            PushManager.shared.handleTap(response.notification.request.content.userInfo)
        }
    }
}
