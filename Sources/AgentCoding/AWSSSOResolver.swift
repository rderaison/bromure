import CommonCrypto
import Foundation

public struct ResolvedAWSCredentials: Sendable {
    public let accessKeyID: String
    public let secretAccessKey: String
    public let sessionToken: String
    public let region: String
    public let expiration: Date
}

public enum AWSSSOResolver {

    public enum Error: Swift.Error, LocalizedError {
        case noProfile(String)
        case loginFailed(String)
        case tokenExpired
        case credentialFetchFailed(String)

        public var errorDescription: String? {
            switch self {
            case .noProfile(let name):      return "SSO profile '\(name)' not found in ~/.aws/config"
            case .loginFailed(let reason):  return "AWS SSO login failed: \(reason)"
            case .tokenExpired:             return "SSO token is expired and login was not completed"
            case .credentialFetchFailed(let reason): return "Failed to get role credentials: \(reason)"
            }
        }
    }

    // MARK: - Public

    public static func resolve(
        profileName: String,
        triggerLoginIfNeeded: Bool = true,
        progress: ((String) -> Void)? = nil
    ) async throws -> ResolvedAWSCredentials {
        let profiles = AWSConfigParser.discover()
        guard let profile = profiles.first(where: { $0.name == profileName }) else {
            throw Error.noProfile(profileName)
        }

        let ssoRegion = profile.ssoRegion.isEmpty ? profile.region : profile.ssoRegion

        if let cached = readCachedToken(startURL: profile.ssoStartURL, ssoRegion: ssoRegion, sessionName: profile.ssoSessionName) {
            let creds = try await getRoleCredentials(
                accessToken: cached,
                accountID: profile.ssoAccountID,
                roleName: profile.ssoRoleName,
                ssoRegion: ssoRegion
            )
            return ResolvedAWSCredentials(
                accessKeyID: creds.accessKeyID,
                secretAccessKey: creds.secretAccessKey,
                sessionToken: creds.sessionToken,
                region: profile.region,
                expiration: creds.expiration
            )
        }

        guard triggerLoginIfNeeded else {
            throw Error.tokenExpired
        }

        progress?("SSO login required — opening browser…")
        try await runSSOLogin(profileName: profileName)

        guard let token = readCachedToken(startURL: profile.ssoStartURL, ssoRegion: ssoRegion, sessionName: profile.ssoSessionName) else {
            throw Error.tokenExpired
        }

        let creds = try await getRoleCredentials(
            accessToken: token,
            accountID: profile.ssoAccountID,
            roleName: profile.ssoRoleName,
            ssoRegion: ssoRegion
        )
        return ResolvedAWSCredentials(
            accessKeyID: creds.accessKeyID,
            secretAccessKey: creds.secretAccessKey,
            sessionToken: creds.sessionToken,
            region: profile.region,
            expiration: creds.expiration
        )
    }

    public static func startRefreshLoop(
        profileName: String,
        initialExpiration: Date,
        onRefresh: @escaping (ResolvedAWSCredentials) -> Void,
        onError: @escaping (Swift.Error) -> Void
    ) -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            var expiration = initialExpiration
            while !Task.isCancelled {
                let refreshAt = expiration.addingTimeInterval(-5 * 60)
                let delay = max(refreshAt.timeIntervalSinceNow, 30)
                try? await Task.sleep(for: .seconds(delay))
                if Task.isCancelled { break }

                do {
                    let creds = try await resolve(
                        profileName: profileName,
                        triggerLoginIfNeeded: false
                    )
                    expiration = creds.expiration
                    onRefresh(creds)
                } catch {
                    onError(error)
                    break
                }
            }
        }
    }

    // MARK: - SSO Token Cache

    private static func readCachedToken(startURL: String, ssoRegion: String, sessionName: String?) -> String? {
        let cacheDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".aws/sso/cache", isDirectory: true)

        // Try direct hash lookup: SHA1("startUrl|region")
        let sessionKey = "\(startURL)|\(ssoRegion)"
        let hashFile = cacheDir.appendingPathComponent("\(sha1Hex(sessionKey)).json")
        if let token = extractValidToken(from: hashFile) {
            return token
        }

        // Also try SHA1(startURL) for older CLIs
        let legacyFile = cacheDir.appendingPathComponent("\(sha1Hex(startURL)).json")
        if let token = extractValidToken(from: legacyFile) {
            return token
        }

        // Fallback: scan all cache files for a match by content
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: cacheDir, includingPropertiesForKeys: nil) else {
            return nil
        }

        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let accessToken = json["accessToken"] as? String else {
                continue
            }

            // Match by session name (sso-session profiles)
            if let sessionName, let fileSession = json["sessionName"] as? String,
               fileSession == sessionName {
                if let token = extractValidToken(accessToken: accessToken,
                                                  expiresAtString: json["expiresAt"] as? String) {
                    return token
                }
            }

            // Match by startUrl + region fields
            if let storedURL = json["startUrl"] as? String,
               let storedRegion = json["region"] as? String,
               storedURL == startURL && storedRegion == ssoRegion {
                if let token = extractValidToken(accessToken: accessToken,
                                                  expiresAtString: json["expiresAt"] as? String) {
                    return token
                }
            }
        }

        return nil
    }

    private static func extractValidToken(from file: URL) -> String? {
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["accessToken"] as? String else {
            return nil
        }
        return extractValidToken(accessToken: accessToken,
                                  expiresAtString: json["expiresAt"] as? String)
    }

    private static func extractValidToken(accessToken: String, expiresAtString: String?) -> String? {
        guard let expiresAtString else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let expiresAt = formatter.date(from: expiresAtString)
                ?? ISO8601DateFormatter().date(from: expiresAtString) else {
            return nil
        }
        if expiresAt.timeIntervalSinceNow < 5 * 60 { return nil }
        return accessToken
    }

    private static func sha1Hex(_ string: String) -> String {
        let data = Data(string.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        data.withUnsafeBytes { ptr in
            _ = CC_SHA1(ptr.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - SSO Login

    private static func runSSOLogin(profileName: String) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Swift.Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/local/bin/aws")
                process.arguments = ["sso", "login", "--profile", profileName]

                let errPipe = Pipe()
                process.standardError = errPipe
                process.standardOutput = FileHandle.nullDevice

                do {
                    try process.run()
                    process.waitUntilExit()
                    if process.terminationStatus == 0 {
                        cont.resume()
                    } else {
                        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                        let errStr = String(data: errData, encoding: .utf8) ?? "exit \(process.terminationStatus)"
                        cont.resume(throwing: Error.loginFailed(errStr.trimmingCharacters(in: .whitespacesAndNewlines)))
                    }
                } catch {
                    cont.resume(throwing: Error.loginFailed(error.localizedDescription))
                }
            }
        }
    }

    // MARK: - GetRoleCredentials

    private struct RoleCredentials {
        let accessKeyID: String
        let secretAccessKey: String
        let sessionToken: String
        let expiration: Date
    }

    private static func getRoleCredentials(
        accessToken: String,
        accountID: String,
        roleName: String,
        ssoRegion: String
    ) async throws -> RoleCredentials {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "portal.sso.\(ssoRegion).amazonaws.com"
        components.path = "/federation/credentials"
        components.queryItems = [
            URLQueryItem(name: "role_name", value: roleName),
            URLQueryItem(name: "account_id", value: accountID),
        ]

        guard let url = components.url else {
            throw Error.credentialFetchFailed("invalid URL")
        }

        var request = URLRequest(url: url)
        request.setValue(accessToken, forHTTPHeaderField: "x-amz-sso_bearer_token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw Error.credentialFetchFailed("non-HTTP response")
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw Error.credentialFetchFailed("HTTP \(http.statusCode): \(body)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roleCreds = json["roleCredentials"] as? [String: Any],
              let akid = roleCreds["accessKeyId"] as? String,
              let secret = roleCreds["secretAccessKey"] as? String,
              let token = roleCreds["sessionToken"] as? String,
              let expirationMs = roleCreds["expiration"] as? Int64 else {
            throw Error.credentialFetchFailed("unexpected response format")
        }

        let expiration = Date(timeIntervalSince1970: Double(expirationMs) / 1000.0)

        return RoleCredentials(
            accessKeyID: akid,
            secretAccessKey: secret,
            sessionToken: token,
            expiration: expiration
        )
    }
}
