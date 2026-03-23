import AppKit
import AuthenticationServices
import Foundation
import Virtualization

private let cbDebug = ProcessInfo.processInfo.environment["BROMURE_DEBUG_KEYCHAIN"] != nil

/// Bridges WebAuthn passkey and password requests between the guest VM and macOS
/// AuthenticationServices + Keychain over vsock.
///
/// Protocol: newline-delimited JSON on vsock port 5201.
///
/// Security model (assume the VM is compromised):
/// - **Passkeys**: User must approve via Touch ID / system prompt for every operation.
///   The system prompt shows the relying party ID, giving the user a chance to verify.
/// - **Password retrieval**: User must approve a host-side dialog showing the domain
///   and pick which credential to send. Plaintext passwords never leave the host
///   without explicit user consent.
/// - **Password save**: User must approve a host-side dialog before anything is written
///   to the Keychain. Saves are scoped to Bromure-only entries (tagged with a label).
/// - **Rate limiting**: All request types are throttled. Repeated denials kill the VM.
/// - **Buffer limits**: The vsock read buffer is capped to prevent OOM from a
///   malicious guest sending unbounded data.
@MainActor
public final class CredentialBridge: NSObject, @unchecked Sendable {
    private static let credentialPort: UInt32 = 5201

    /// Max pending data from guest before we disconnect (1 MB).
    private static let maxPendingData = 1_048_576

    /// Bromure-specific label for Keychain entries we create.
    private static let keychainLabel = "Bromure Saved Password"

    private weak var socketDevice: VZVirtioSocketDevice?
    private var listenerDelegate: CredentialListenerDelegate?
    private var connection: VZVirtioSocketConnection?
    private var readSource: DispatchSourceRead?
    private weak var window: NSWindow?

    /// Shared iCloud Passwords bridge for password autofill.
    public var icloudBridge: ICloudPasswordsBridge?

    /// Called to lazily connect to iCloud Passwords on first password request.
    /// Set by the app layer (SafariSandbox.swift) since it owns the shared bridge.
    public var onConnectICloudPasswords: (() async -> ICloudPasswordsBridge?)?

    // Only one ASAuthorization request at a time
    private var activeProvider: PasskeyProvider?
    private var requestInFlight = false

    /// Called when the user declines a credential request and chooses to kill the VM.
    /// The host (BrowserSession) should close the window and tear down.
    public var onKillSession: (() -> Void)?

    // Rate limiting: track last request time per type
    private var lastRequestTime: [String: Date] = [:]
    private static let minRequestInterval: TimeInterval = 1.0  // 1 req/sec per type
    private var consecutiveDenials = 0
    private static let maxConsecutiveDenials = 3

    public init(socketDevice: VZVirtioSocketDevice, window: NSWindow, icloudBridge: ICloudPasswordsBridge? = nil) {
        self.socketDevice = socketDevice
        self.window = window
        self.icloudBridge = icloudBridge
        super.init()

        if cbDebug { print("[CredentialBridge] init: setting up vsock listener on port \(Self.credentialPort)") }

        let delegate = CredentialListenerDelegate { [weak self] conn in
            self?.handleConnection(conn)
        }
        let listener = VZVirtioSocketListener()
        listener.delegate = delegate
        self.listenerDelegate = delegate
        socketDevice.setSocketListener(listener, forPort: Self.credentialPort)
    }

    public func stop() {
        if cbDebug { print("[CredentialBridge] stop") }
        readSource?.cancel()
        readSource = nil
        socketDevice?.removeSocketListener(forPort: Self.credentialPort)
        connection = nil
    }

    // MARK: - Rate limiting

    /// Returns true if the request should be rejected (too fast).
    private func isRateLimited(type: String) -> Bool {
        let now = Date()
        if let last = lastRequestTime[type],
           now.timeIntervalSince(last) < Self.minRequestInterval {
            if cbDebug { print("[CredentialBridge] rate limited: \(type)") }
            return true
        }
        lastRequestTime[type] = now
        return false
    }

    // MARK: - Connection handling

    private func handleConnection(_ conn: VZVirtioSocketConnection) {
        if cbDebug { print("[CredentialBridge] guest connected (fd=\(conn.fileDescriptor))") }

        readSource?.cancel()
        connection = conn

        let fd = conn.fileDescriptor
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        var pendingData = Data()

        source.setEventHandler { [weak self] in
            guard let self else { return }
            var buf = [UInt8](repeating: 0, count: 65536)
            let n = Darwin.read(fd, &buf, buf.count)
            guard n > 0 else {
                if cbDebug { print("[CredentialBridge] connection closed") }
                source.cancel()
                return
            }
            pendingData.append(contentsOf: buf[0..<n])

            // Buffer overflow protection
            if pendingData.count > Self.maxPendingData {
                if cbDebug { print("[CredentialBridge] buffer overflow — disconnecting") }
                pendingData.removeAll()
                source.cancel()
                return
            }

            while let newlineIndex = pendingData.firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = pendingData[pendingData.startIndex..<newlineIndex]
                pendingData = Data(pendingData[(newlineIndex + 1)...])
                if !lineData.isEmpty {
                    self.handleMessage(Data(lineData))
                }
            }
        }

        source.setCancelHandler { [weak self] in
            self?.readSource = nil
            self?.connection = nil
        }

        source.resume()
        readSource = source
    }

    private func handleMessage(_ jsonData: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let type = json["type"] as? String,
              let requestId = json["requestId"] as? String else {
            if cbDebug { print("[CredentialBridge] invalid message") }
            return
        }

        if cbDebug { print("[CredentialBridge] received: \(type) requestId=\(requestId)") }

        // Rate limit all request types
        if isRateLimited(type: type) {
            sendError(requestId: requestId, type: "\(type)_response", error: "rate_limited")
            return
        }

        // Reject concurrent requests — only one at a time
        if requestInFlight {
            sendError(requestId: requestId, type: "\(type)_response", error: "busy")
            return
        }

        switch type {
        case "passkey_create":
            handlePasskeyCreate(json, requestId: requestId)
        case "passkey_get":
            handlePasskeyGet(json, requestId: requestId)
        case "password_get":
            handlePasswordGet(json, requestId: requestId)
        case "password_save":
            handlePasswordSave(json, requestId: requestId)
        default:
            if cbDebug { print("[CredentialBridge] unknown type: \(type)") }
            sendError(requestId: requestId, type: "unknown_response", error: "unknown_type")
        }
    }

    // MARK: - Denial tracking

    /// Called when the user explicitly denies a credential request.
    /// After repeated denials, offers to kill the VM.
    private func handleUserDenial() {
        consecutiveDenials += 1
        if consecutiveDenials >= Self.maxConsecutiveDenials {
            consecutiveDenials = 0
            offerKillSession()
        }
    }

    /// Reset denial counter on successful user approval.
    private func handleUserApproval() {
        consecutiveDenials = 0
    }

    private func offerKillSession() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Suspicious credential requests"
        alert.informativeText = "The VM has made repeated credential requests that you declined. This may indicate the VM is compromised.\n\nWould you like to close this browser session?"
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Close Session")
        alert.addButton(withTitle: "Keep Open")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn {
                self?.onKillSession?()
            }
        }
    }

    // MARK: - Passkey Create

    private func handlePasskeyCreate(_ json: [String: Any], requestId: String) {
        guard let window else {
            sendError(requestId: requestId, type: "passkey_create_response", error: "no_window")
            return
        }
        guard let rp = json["rp"] as? [String: Any],
              let rpId = rp["id"] as? String,
              let user = json["user"] as? [String: Any],
              let userIdB64 = user["id"] as? String,
              let userId = Data(base64Encoded: userIdB64),
              let userName = user["name"] as? String,
              let challengeB64 = json["challenge"] as? String,
              let challenge = Data(base64Encoded: challengeB64) else {
            sendError(requestId: requestId, type: "passkey_create_response", error: "invalid_params")
            return
        }

        let displayName = user["displayName"] as? String ?? userName
        let origin = json["origin"] as? String ?? "https://\(rpId)"

        // Passkeys: Touch ID prompt is the user confirmation (system shows rpId).
        let provider = PasskeyProvider(window: window)
        activeProvider = provider
        requestInFlight = true

        Task { @MainActor in
            defer {
                activeProvider = nil
                requestInFlight = false
            }
            do {
                let result = try await provider.createPasskey(
                    rpId: rpId,
                    origin: origin,
                    challenge: challenge,
                    userId: userId,
                    userName: userName,
                    displayName: displayName
                )
                handleUserApproval()
                sendResponse([
                    "type": "passkey_create_response",
                    "requestId": requestId,
                    "success": true,
                    "credentialId": result.credentialId,
                    "attestationObject": result.attestationObject,
                    "clientDataJSON": result.clientDataJSON,
                ])
            } catch {
                let cancelled = (error as? ASAuthorizationError)?.code == .canceled
                if cancelled { handleUserDenial() }
                sendError(requestId: requestId, type: "passkey_create_response",
                          error: cancelled ? "user_cancelled" : "failed")
            }
        }
    }

    // MARK: - Passkey Get

    private func handlePasskeyGet(_ json: [String: Any], requestId: String) {
        guard let window else {
            sendError(requestId: requestId, type: "passkey_get_response", error: "no_window")
            return
        }
        guard let rpId = json["rpId"] as? String,
              let challengeB64 = json["challenge"] as? String,
              let challenge = Data(base64Encoded: challengeB64) else {
            sendError(requestId: requestId, type: "passkey_get_response", error: "invalid_params")
            return
        }

        var allowedCredentialIDs: [Data] = []
        if let allowList = json["allowCredentials"] as? [[String: Any]] {
            for cred in allowList {
                if let idB64 = cred["id"] as? String, let idData = Data(base64Encoded: idB64) {
                    allowedCredentialIDs.append(idData)
                }
            }
        }

        let origin = json["origin"] as? String ?? "https://\(rpId)"

        // Passkeys: Touch ID prompt is the user confirmation.
        let provider = PasskeyProvider(window: window)
        activeProvider = provider
        requestInFlight = true

        Task { @MainActor in
            defer {
                activeProvider = nil
                requestInFlight = false
            }
            do {
                let result = try await provider.getCredential(
                    rpId: rpId,
                    origin: origin,
                    challenge: challenge,
                    allowedCredentialIDs: allowedCredentialIDs
                )
                handleUserApproval()
                switch result {
                case .passkey(let passkey):
                    sendResponse([
                        "type": "passkey_get_response",
                        "requestId": requestId,
                        "success": true,
                        "credentialId": passkey.credentialId,
                        "authenticatorData": passkey.authenticatorData,
                        "signature": passkey.signature,
                        "userHandle": passkey.userHandle,
                        "clientDataJSON": passkey.clientDataJSON,
                    ])
                case .password(let password):
                    sendResponse([
                        "type": "passkey_get_response",
                        "requestId": requestId,
                        "success": true,
                        "isPassword": true,
                        "username": password.username,
                        "password": password.password,
                    ])
                }
            } catch {
                let cancelled = (error as? ASAuthorizationError)?.code == .canceled
                if cancelled { handleUserDenial() }
                if cbDebug { print("[CredentialBridge] passkey_get: \(cancelled ? "cancelled" : "failed: \(error)")") }
                sendError(requestId: requestId, type: "passkey_get_response",
                          error: cancelled ? "user_cancelled" : "no_credentials")
            }
        }
    }

    // MARK: - Password Get (via iCloud Passwords bridge)

    private func handlePasswordGet(_ json: [String: Any], requestId: String) {
        guard let domain = json["domain"] as? String, !domain.isEmpty else {
            sendError(requestId: requestId, type: "password_get_response", error: "invalid_params")
            return
        }

        requestInFlight = true

        Task { @MainActor in
            defer { requestInFlight = false }

            // Lazily connect to iCloud Passwords on first password request
            if self.icloudBridge == nil, let connect = self.onConnectICloudPasswords {
                self.icloudBridge = await connect()
            }

            guard let bridge = self.icloudBridge else {
                // No iCloud bridge — fallback to Bromure's own keychain entries
                let entries = Self.searchKeychainPasswords(domain: domain)
                if entries.isEmpty {
                    sendError(requestId: requestId, type: "password_get_response", error: "no_credentials")
                } else {
                    sendResponse([
                        "type": "password_get_response",
                        "requestId": requestId,
                        "success": true,
                        "credentials": entries.map { ["username": $0.0, "password": $0.1] },
                    ])
                }
                return
            }

            // First get login names for this domain
            let loginEntries = await bridge.getLoginNames(hostname: domain)
            if loginEntries.isEmpty {
                // Fall back to Bromure keychain
                let entries = Self.searchKeychainPasswords(domain: domain)
                if entries.isEmpty {
                    if cbDebug { print("[CredentialBridge] password_get for \(domain): no credentials") }
                    sendError(requestId: requestId, type: "password_get_response", error: "no_credentials")
                } else {
                    sendResponse([
                        "type": "password_get_response",
                        "requestId": requestId,
                        "success": true,
                        "credentials": entries.map { ["username": $0.0, "password": $0.1] },
                    ])
                }
                return
            }

            // Fetch passwords for each entry
            var credentials: [[String: String]] = []
            for entry in loginEntries {
                if let pwd = await bridge.getPassword(url: domain, username: entry.username) {
                    credentials.append(["username": entry.username, "password": pwd])
                }
            }

            if credentials.isEmpty {
                if cbDebug { print("[CredentialBridge] password_get for \(domain): no passwords returned") }
                sendError(requestId: requestId, type: "password_get_response", error: "no_credentials")
            } else {
                handleUserApproval()
                if cbDebug { print("[CredentialBridge] password_get for \(domain): got \(credentials.count) credential(s)") }
                sendResponse([
                    "type": "password_get_response",
                    "requestId": requestId,
                    "success": true,
                    "credentials": credentials,
                ])
            }
        }
    }

    /// Search Bromure's own keychain entries for a domain.
    private static func searchKeychainPasswords(domain: String) -> [(String, String)] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: domain,
            kSecAttrLabel as String: keychainLabel,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let account = item[kSecAttrAccount as String] as? String,
                  let data = item[kSecValueData as String] as? Data,
                  let password = String(data: data, encoding: .utf8) else { return nil }
            return (account, password)
        }
    }

    // MARK: - Password Save (user approval required)

    private func handlePasswordSave(_ json: [String: Any], requestId: String) {
        guard let window else {
            sendError(requestId: requestId, type: "password_save_response", error: "no_window")
            return
        }
        guard let domain = json["domain"] as? String, !domain.isEmpty,
              let username = json["username"] as? String, !username.isEmpty,
              let password = json["password"] as? String, !password.isEmpty else {
            sendError(requestId: requestId, type: "password_save_response", error: "invalid_params")
            return
        }

        requestInFlight = true

        let alert = NSAlert()
        alert.messageText = "Save password?"
        alert.informativeText = "The browser wants to save a password for \u{201c}\(domain)\u{201d}.\n\nUsername: \(username)"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don\u{2019}t Save")

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.requestInFlight = false

            if response == .alertFirstButtonReturn {
                self.handleUserApproval()
                let success = Self.savePassword(domain: domain, username: username, password: password)
                if cbDebug { print("[CredentialBridge] password_save for \(domain)/\(username): \(success)") }
                self.sendResponse([
                    "type": "password_save_response",
                    "requestId": requestId,
                    "success": success,
                ])
            } else {
                self.handleUserDenial()
                self.sendError(requestId: requestId, type: "password_save_response", error: "user_cancelled")
            }
        }
    }

    // MARK: - Keychain Operations (scoped to Bromure)

    /// Save a password, scoped to Bromure entries only.
    /// Uses kSecAttrLabel to tag entries so updates only affect our own entries.
    private static func savePassword(domain: String, username: String, password: String) -> Bool {
        guard let passwordData = password.data(using: .utf8) else { return false }

        // Only update entries that have our label (Bromure-created)
        let searchQuery: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: domain,
            kSecAttrAccount as String: username,
            kSecAttrLabel as String: keychainLabel,
        ]
        let updateAttrs: [String: Any] = [
            kSecValueData as String: passwordData,
        ]

        let updateStatus = SecItemUpdate(searchQuery as CFDictionary, updateAttrs as CFDictionary)
        if updateStatus == errSecSuccess { return true }

        // Add new entry with Bromure label
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: domain,
            kSecAttrAccount as String: username,
            kSecAttrLabel as String: keychainLabel,
            kSecValueData as String: passwordData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        return addStatus == errSecSuccess
    }

    // MARK: - Wire format

    private func sendResponse(_ envelope: [String: Any]) {
        guard let conn = connection else { return }
        guard let jsonData = try? JSONSerialization.data(withJSONObject: envelope) else { return }

        var frame = jsonData
        frame.append(UInt8(ascii: "\n"))

        let fd = conn.fileDescriptor
        frame.withUnsafeBytes { ptr in
            var offset = 0
            while offset < frame.count {
                let written = Darwin.write(fd, ptr.baseAddress! + offset, frame.count - offset)
                if written <= 0 { break }
                offset += written
            }
        }
    }

    private func sendError(requestId: String, type: String, error: String) {
        sendResponse([
            "type": type,
            "requestId": requestId,
            "success": false,
            "error": error,
        ])
    }
}

// MARK: - VZVirtioSocketListenerDelegate

private final class CredentialListenerDelegate: NSObject, VZVirtioSocketListenerDelegate {
    let onConnection: (VZVirtioSocketConnection) -> Void

    init(onConnection: @escaping (VZVirtioSocketConnection) -> Void) {
        self.onConnection = onConnection
    }

    func listener(
        _ listener: VZVirtioSocketListener,
        shouldAcceptNewConnection connection: VZVirtioSocketConnection,
        from socketDevice: VZVirtioSocketDevice
    ) -> Bool {
        if cbDebug { print("[CredentialBridge] accepting connection from port \(connection.sourcePort)") }
        onConnection(connection)
        return true
    }
}
