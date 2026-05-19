import AppKit
import CryptoKit
import Foundation

/// Handles MCP OAuth discovery, dynamic client registration, and
/// authorization-code-with-PKCE flow for HTTP MCP servers. Runs entirely
/// on the host — the VM never sees real OAuth credentials.
///
/// Uses a localhost HTTP listener for the OAuth callback because MCP
/// servers (e.g. Fellow) reject custom URL schemes in redirect_uris.
@MainActor
public final class MCPOAuthBroker {

    public enum BrokerError: Error, LocalizedError {
        case discoveryFailed(String)
        case registrationFailed(String)
        case authorizationCancelled
        case tokenExchangeFailed(String)
        case refreshFailed(String)

        public var errorDescription: String? {
            switch self {
            case .discoveryFailed(let msg):     return "OAuth discovery failed: \(msg)"
            case .registrationFailed(let msg):  return "Client registration failed: \(msg)"
            case .authorizationCancelled:       return "Authorization was cancelled"
            case .tokenExchangeFailed(let msg): return "Token exchange failed: \(msg)"
            case .refreshFailed(let msg):       return "Token refresh failed: \(msg)"
            }
        }
    }

    struct AuthMetadata {
        let authorizationEndpoint: URL
        let tokenEndpoint: URL
        let registrationEndpoint: URL?
    }

    struct ClientRegistration {
        let clientID: String
        let clientSecret: String?
    }

    public struct AuthResult {
        public let accessToken: String
        public let refreshToken: String?
        public let expiresIn: Int?
        public let clientID: String
        public let clientSecret: String?
        public let authorizationEndpoint: String
        public let tokenEndpoint: String
        public let registrationEndpoint: String?
        public let callbackPort: UInt16
    }

    deinit {
        if listenFD >= 0 { close(listenFD) }
    }

    // MARK: - Public API

    public func authorizeServer(url: String, existingState: MCPOAuthState? = nil) async throws -> AuthResult {
        guard let serverURL = URL(string: url) else {
            throw BrokerError.discoveryFailed("Invalid URL")
        }
        let metadata: AuthMetadata
        if let st = existingState,
           let authURL = URL(string: st.authorizationEndpoint),
           let tokenURL = URL(string: st.tokenEndpoint) {
            metadata = AuthMetadata(
                authorizationEndpoint: authURL,
                tokenEndpoint: tokenURL,
                registrationEndpoint: st.registrationEndpoint.flatMap(URL.init(string:))
            )
        } else {
            metadata = try await discoverMetadata(serverURL: serverURL)
        }
        let preferredPort = existingState?.callbackPort
        let (redirectURI, port) = try startCallbackListener(preferredPort: preferredPort)
        let canReuseClient = preferredPort != nil && port == preferredPort
        do {
            let client: ClientRegistration
            if let st = existingState, !st.clientID.isEmpty, canReuseClient {
                client = ClientRegistration(clientID: st.clientID, clientSecret: st.clientSecret)
            } else {
                client = try await registerClient(metadata: metadata, redirectURI: redirectURI)
            }
            let (code, verifier) = try await authorize(
                metadata: metadata, client: client, redirectURI: redirectURI, port: port)
            return try await exchangeCode(
                code, metadata: metadata, client: client,
                codeVerifier: verifier, redirectURI: redirectURI,
                callbackPort: port)
        } catch {
            if listenFD >= 0 { close(listenFD); listenFD = -1 }
            throw error
        }
    }

    public static func refresh(state: MCPOAuthState) async throws -> MCPOAuthState {
        guard let refreshToken = state.refreshToken,
              let tokenURL = URL(string: state.tokenEndpoint) else {
            throw BrokerError.refreshFailed("No refresh token or invalid token endpoint")
        }
        var body = [
            "grant_type=refresh_token",
            "refresh_token=\(formEncode(refreshToken))",
            "client_id=\(formEncode(state.clientID))",
        ]
        if let secret = state.clientSecret {
            body.append("client_secret=\(formEncode(secret))")
        }
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.joined(separator: "&").utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw BrokerError.refreshFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String else {
            throw BrokerError.refreshFailed("Missing access_token in response")
        }
        var updated = state
        updated.accessToken = accessToken
        if let rt = json["refresh_token"] as? String {
            updated.refreshToken = rt
        }
        if let exp = json["expires_in"] as? Int {
            updated.expiresAt = Date().addingTimeInterval(TimeInterval(exp))
        }
        return updated
    }

    // MARK: - Localhost Callback Listener (POSIX socket)

    static let portRangeStart: UInt16 = 28500
    static let portRangeEnd: UInt16 = 28599
    private var listenFD: Int32 = -1

    private func startCallbackListener(preferredPort: UInt16? = nil) throws -> (redirectURI: String, port: UInt16) {
        var candidates: [UInt16] = []
        if let p = preferredPort, p >= Self.portRangeStart, p <= Self.portRangeEnd {
            candidates.append(p)
        }
        for p in Self.portRangeStart...Self.portRangeEnd where !candidates.contains(p) {
            candidates.append(p)
        }
        for port in candidates {
            if let fd = tryBind(port: port) {
                self.listenFD = fd
                return ("http://127.0.0.1:\(port)/callback", port)
            }
        }
        throw BrokerError.discoveryFailed(
            "No available port in \(Self.portRangeStart)–\(Self.portRangeEnd)")
    }

    private func tryBind(port: UInt16) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = UInt32(INADDR_LOOPBACK).bigEndian
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard ok == 0, listen(fd, 1) == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    private func waitForCallback(state: String) async throws -> String {
        let fd = self.listenFD
        guard fd >= 0 else { throw BrokerError.authorizationCancelled }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let client = accept(fd, nil, nil)
                defer {
                    close(client)
                    close(fd)
                }
                guard client >= 0 else {
                    continuation.resume(throwing: BrokerError.authorizationCancelled)
                    return
                }
                var buf = [UInt8](repeating: 0, count: 8192)
                let n = recv(client, &buf, buf.count, 0)
                guard n > 0,
                      let raw = String(bytes: buf[..<n], encoding: .utf8),
                      let requestLine = raw.components(separatedBy: "\r\n").first,
                      let pathPart = requestLine.split(separator: " ").dropFirst().first,
                      let components = URLComponents(string: String(pathPart)),
                      let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
                      let returnedState = components.queryItems?.first(where: { $0.name == "state" })?.value,
                      returnedState == state else {
                    let body = "Authorization failed."
                    let resp = "HTTP/1.1 400 Bad Request\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                    _ = send(client, resp, resp.utf8.count, 0)
                    continuation.resume(throwing: BrokerError.tokenExchangeFailed(
                        "Invalid callback — missing code or state mismatch"))
                    return
                }
                let body = "<html><body style=\"font-family:system-ui;text-align:center;padding:60px\">" +
                    "<h2>Authorized</h2><p>You can close this tab and return to Bromure AC.</p></body></html>"
                let resp = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                _ = send(client, resp, resp.utf8.count, 0)
                continuation.resume(returning: code)
            }
        }
    }

    // MARK: - Discovery (RFC 8414)

    private func discoverMetadata(serverURL: URL) async throws -> AuthMetadata {
        guard var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false) else {
            throw BrokerError.discoveryFailed("Cannot parse URL")
        }
        components.path = "/.well-known/oauth-authorization-server"
        components.query = nil
        components.fragment = nil
        guard let discoveryURL = components.url else {
            throw BrokerError.discoveryFailed("Cannot construct discovery URL")
        }
        let (data, response) = try await URLSession.shared.data(from: discoveryURL)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw BrokerError.discoveryFailed(
                "Server returned \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let authEP = json["authorization_endpoint"] as? String,
              let authURL = URL(string: authEP),
              let tokenEP = json["token_endpoint"] as? String,
              let tokenURL = URL(string: tokenEP) else {
            throw BrokerError.discoveryFailed("Missing required endpoints in metadata")
        }
        let regEP = (json["registration_endpoint"] as? String).flatMap(URL.init(string:))
        return AuthMetadata(
            authorizationEndpoint: authURL,
            tokenEndpoint: tokenURL,
            registrationEndpoint: regEP
        )
    }

    // MARK: - Dynamic Client Registration (RFC 7591)

    private func registerClient(
        metadata: AuthMetadata, redirectURI: String
    ) async throws -> ClientRegistration {
        guard let regURL = metadata.registrationEndpoint else {
            throw BrokerError.registrationFailed(
                "Server does not support dynamic client registration")
        }
        let payload: [String: Any] = [
            "client_name": "Bromure AC",
            "redirect_uris": [redirectURI],
            "grant_types": ["authorization_code"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none",
        ]
        var request = URLRequest(url: regURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...201).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw BrokerError.registrationFailed(
                "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0): \(body)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let clientID = json["client_id"] as? String else {
            throw BrokerError.registrationFailed("Missing client_id in response")
        }
        return ClientRegistration(
            clientID: clientID,
            clientSecret: json["client_secret"] as? String
        )
    }

    // MARK: - Authorization (PKCE + System Browser)

    private func authorize(
        metadata: AuthMetadata,
        client: ClientRegistration,
        redirectURI: String,
        port: UInt16
    ) async throws -> (code: String, verifier: String) {
        let verifier = Self.generateCodeVerifier()
        let challenge = Self.codeChallenge(for: verifier)
        let state = UUID().uuidString

        var components = URLComponents(url: metadata.authorizationEndpoint,
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: client.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        guard let authURL = components.url else {
            throw BrokerError.discoveryFailed("Cannot construct authorization URL")
        }
        NSWorkspace.shared.open(authURL)
        let code = try await waitForCallback(state: state)
        return (code, verifier)
    }

    // MARK: - Token Exchange

    private func exchangeCode(
        _ code: String,
        metadata: AuthMetadata,
        client: ClientRegistration,
        codeVerifier: String,
        redirectURI: String,
        callbackPort: UInt16
    ) async throws -> AuthResult {
        var body = [
            "grant_type=authorization_code",
            "code=\(Self.formEncode(code))",
            "redirect_uri=\(Self.formEncode(redirectURI))",
            "client_id=\(Self.formEncode(client.clientID))",
            "code_verifier=\(Self.formEncode(codeVerifier))",
        ]
        if let secret = client.clientSecret {
            body.append("client_secret=\(Self.formEncode(secret))")
        }
        var request = URLRequest(url: metadata.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.joined(separator: "&").utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw BrokerError.tokenExchangeFailed(
                "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String else {
            throw BrokerError.tokenExchangeFailed("Missing access_token in response")
        }
        return AuthResult(
            accessToken: accessToken,
            refreshToken: json["refresh_token"] as? String,
            expiresIn: json["expires_in"] as? Int,
            clientID: client.clientID,
            clientSecret: client.clientSecret,
            authorizationEndpoint: metadata.authorizationEndpoint.absoluteString,
            tokenEndpoint: metadata.tokenEndpoint.absoluteString,
            registrationEndpoint: metadata.registrationEndpoint?.absoluteString,
            callbackPort: callbackPort
        )
    }

    // MARK: - PKCE Helpers

    private static func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static let formSafeCharacters: CharacterSet = {
        var cs = CharacterSet.alphanumerics
        cs.insert(charactersIn: "-._~")
        return cs
    }()

    private static func formEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: formSafeCharacters) ?? value
    }
}
