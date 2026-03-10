import AppKit
import AuthenticationServices
import Foundation
import Virtualization

private let cbDebug = ProcessInfo.processInfo.environment["BROMURE_DEBUG"] != nil

/// Bridges WebAuthn passkey and password requests between the guest VM and macOS
/// AuthenticationServices + Keychain over vsock.
///
/// Protocol: newline-delimited JSON on vsock port 5200.
///
/// Request types (guest → host):
/// - "passkey_create"  — create a new passkey via platform authenticator
/// - "passkey_get"     — assert an existing passkey
/// - "password_get"    — retrieve saved passwords for a domain
/// - "password_save"   — store a password in the macOS Keychain
///
/// Each request carries a "requestId" (UUID string) echoed in the response.
@MainActor
public final class CredentialBridge: NSObject, @unchecked Sendable {
    private static let credentialPort: UInt32 = 5200

    private weak var socketDevice: VZVirtioSocketDevice?
    private var listenerDelegate: CredentialListenerDelegate?
    private var connection: VZVirtioSocketConnection?
    private var readSource: DispatchSourceRead?
    private weak var window: NSWindow?

    // Only one ASAuthorization request at a time
    private var activeProvider: PasskeyProvider?

    /// Keychain service for Bromure-saved passwords.
    private static let keychainService = "com.bromure.passwords"

    public init(socketDevice: VZVirtioSocketDevice, window: NSWindow) {
        self.socketDevice = socketDevice
        self.window = window
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

    // MARK: - Connection handling

    private func handleConnection(_ conn: VZVirtioSocketConnection) {
        if cbDebug { print("[CredentialBridge] guest connected (fd=\(conn.fileDescriptor))") }

        readSource?.cancel()
        connection = conn

        let fd = conn.fileDescriptor
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        var pendingData = Data()

        source.setEventHandler { [weak self] in
            var buf = [UInt8](repeating: 0, count: 65536)
            let n = Darwin.read(fd, &buf, buf.count)
            guard n > 0 else {
                if cbDebug { print("[CredentialBridge] connection closed") }
                source.cancel()
                return
            }
            pendingData.append(contentsOf: buf[0..<n])

            while let newlineIndex = pendingData.firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = pendingData[pendingData.startIndex..<newlineIndex]
                pendingData = Data(pendingData[(newlineIndex + 1)...])
                if !lineData.isEmpty {
                    self?.handleMessage(Data(lineData))
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
            sendError(requestId: requestId, type: "\(type)_response", error: "unknown_type")
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

        let provider = PasskeyProvider(window: window)
        activeProvider = provider

        Task { @MainActor in
            do {
                let result = try await provider.createPasskey(
                    rpId: rpId,
                    challenge: challenge,
                    userId: userId,
                    userName: userName,
                    displayName: displayName
                )
                sendResponse([
                    "type": "passkey_create_response",
                    "requestId": requestId,
                    "success": true,
                    "credentialId": result.credentialId,
                    "attestationObject": result.attestationObject,
                    "clientDataJSON": result.clientDataJSON,
                ])
            } catch {
                let errorStr = (error as? ASAuthorizationError)?.code == .canceled
                    ? "user_cancelled" : "failed"
                sendError(requestId: requestId, type: "passkey_create_response", error: errorStr)
            }
            activeProvider = nil
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

        // Parse allowCredentials if present
        var allowedCredentialIDs: [Data] = []
        if let allowList = json["allowCredentials"] as? [[String: Any]] {
            for cred in allowList {
                if let idB64 = cred["id"] as? String, let idData = Data(base64Encoded: idB64) {
                    allowedCredentialIDs.append(idData)
                }
            }
        }

        let provider = PasskeyProvider(window: window)
        activeProvider = provider

        Task { @MainActor in
            do {
                let result = try await provider.getPasskey(
                    rpId: rpId,
                    challenge: challenge,
                    allowedCredentialIDs: allowedCredentialIDs
                )
                sendResponse([
                    "type": "passkey_get_response",
                    "requestId": requestId,
                    "success": true,
                    "credentialId": result.credentialId,
                    "authenticatorData": result.authenticatorData,
                    "signature": result.signature,
                    "userHandle": result.userHandle,
                    "clientDataJSON": result.clientDataJSON,
                ])
            } catch {
                let errorStr = (error as? ASAuthorizationError)?.code == .canceled
                    ? "user_cancelled" : "no_credentials"
                sendError(requestId: requestId, type: "passkey_get_response", error: errorStr)
            }
            activeProvider = nil
        }
    }

    // MARK: - Password Get

    private func handlePasswordGet(_ json: [String: Any], requestId: String) {
        guard let domain = json["domain"] as? String else {
            sendError(requestId: requestId, type: "password_get_response", error: "invalid_params")
            return
        }

        // Query Bromure-saved passwords from Keychain
        let credentials = Self.fetchPasswords(for: domain)

        if cbDebug { print("[CredentialBridge] password_get for \(domain): \(credentials.count) found") }

        var credList: [[String: String]] = []
        for cred in credentials {
            credList.append([
                "username": cred.username,
                "password": cred.password,
                "source": "bromure",
            ])
        }

        sendResponse([
            "type": "password_get_response",
            "requestId": requestId,
            "success": true,
            "credentials": credList,
        ])
    }

    // MARK: - Password Save

    private func handlePasswordSave(_ json: [String: Any], requestId: String) {
        guard let domain = json["domain"] as? String,
              let username = json["username"] as? String,
              let password = json["password"] as? String else {
            sendError(requestId: requestId, type: "password_save_response", error: "invalid_params")
            return
        }

        let success = Self.savePassword(domain: domain, username: username, password: password)
        if cbDebug { print("[CredentialBridge] password_save for \(domain)/\(username): \(success)") }

        sendResponse([
            "type": "password_save_response",
            "requestId": requestId,
            "success": success,
        ])
    }

    // MARK: - Keychain Operations

    private struct SavedCredential {
        let username: String
        let password: String
    }

    private static func fetchPasswords(for domain: String) -> [SavedCredential] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: domain,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            return []
        }

        return items.compactMap { item in
            guard let account = item[kSecAttrAccount as String] as? String,
                  let data = item[kSecValueData as String] as? Data,
                  let password = String(data: data, encoding: .utf8) else { return nil }
            return SavedCredential(username: account, password: password)
        }
    }

    private static func savePassword(domain: String, username: String, password: String) -> Bool {
        guard let passwordData = password.data(using: .utf8) else { return false }

        // Try to update existing entry first
        let searchQuery: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: domain,
            kSecAttrAccount as String: username,
        ]
        let updateAttrs: [String: Any] = [
            kSecValueData as String: passwordData,
        ]

        let updateStatus = SecItemUpdate(searchQuery as CFDictionary, updateAttrs as CFDictionary)
        if updateStatus == errSecSuccess { return true }

        // Add new entry
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: domain,
            kSecAttrAccount as String: username,
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
