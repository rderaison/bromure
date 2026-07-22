import UserNotifications

/// Decrypts an E2E-sealed push on-device before it's shown.
///
/// A push from bromure.io carries the real notification content as an opaque
/// `e2e` HPKE blob (server + Apple never see it) plus a generic APS fallback.
/// This extension opens the blob with the device's X25519 private key — held in
/// the shared keychain access group — and rewrites the banner with the real
/// title/body. Any failure (no key, wrong key, corrupt blob, plain push) simply
/// falls through to the generic fallback.
final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttempt: UNMutableNotificationContent?

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        guard let best = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content)
            return
        }
        bestAttempt = best
        if let blob = request.content.userInfo["e2e"] as? String,
           let key = PushKeypair.privateKey(),
           let plaintext = PushCrypto.open(blob, privateKey: key),
           let obj = try? JSONSerialization.jsonObject(with: plaintext) as? [String: Any] {
            if let title = obj["title"] as? String, !title.isEmpty { best.title = title }
            if let body = obj["body"] as? String, !body.isEmpty { best.body = body }
        }
        contentHandler(best)
    }

    override func serviceExtensionTimeWillExpire() {
        if let contentHandler, let bestAttempt { contentHandler(bestAttempt) }
    }
}
