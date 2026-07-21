import Foundation

// MARK: - Device enrollment (bootstrap)

/// Redeems a one-time enrollment code against the control plane and persists
/// the resulting device identity. This is the two-round-trip key-possession
/// proof from REMOTE_P2P_PLAN.md §"Recommended first-run experience":
///
/// 1. generate an Ed25519 key locally,
/// 2. `POST /v1/devices/enroll {code, devicePubkey}` → challenge + signPayload,
/// 3. sign signPayload, `POST /v1/devices/enroll {challengeId, signature}`,
/// 4. store `{deviceId, deviceToken, …}` in the keychain.
///
/// The web/admin side mints the code and shows it as a `bromure://enroll?…`
/// deep link, a QR, and a copyable string; `EnrollLink` parses any of those.
enum P2PEnroll {
    struct Result: Equatable {
        let record: DeviceRecord
        let userId: String?
    }

    enum EnrollError: Error, Equatable {
        case badCode
        case keychainWriteFailed
        case control(ControlPlaneError)
        case signingFailed
    }

    /// Run the full enroll flow against `link` and persist the identity on
    /// success. `capability` is usually inferred from the code's authorization,
    /// but a caller may assert it (the server rejects a mismatch).
    static func enroll(link: EnrollLink, deviceName: String?, capability: String? = nil,
                       session: URLSession = .shared) async -> Swift.Result<Result, EnrollError> {
        let endpoint: ControlPlaneEndpoint
        do {
            endpoint = try ControlPlaneEndpoint(base: link.apiBase)
        } catch let e as ControlPlaneError {
            return .failure(.control(e))
        } catch {
            return .failure(.control(.badBase(link.apiBase)))
        }
        let client = ControlPlaneClient(endpoint: endpoint, session: session)
        let signingKey = DeviceSigningKey()

        let begin: EnrollBeginResponse
        do {
            begin = try await client.enrollBegin(code: link.code,
                                                 devicePubkeyHex: signingKey.publicKeyHex,
                                                 deviceName: deviceName, capability: capability)
        } catch let e as ControlPlaneError {
            return .failure(.control(e))
        } catch {
            return .failure(.control(.transport("\(error)")))
        }

        guard let signature = signingKey.signBase64(begin.signPayload) else {
            return .failure(.signingFailed)
        }

        let complete: EnrollCompleteResponse
        do {
            complete = try await client.enrollComplete(challengeId: begin.challengeId,
                                                       signatureBase64: signature)
        } catch let e as ControlPlaneError {
            return .failure(.control(e))
        } catch {
            return .failure(.control(.transport("\(error)")))
        }

        let record = DeviceRecord(
            privateKeyHex: signingKey.privateKeyHex,
            deviceToken: complete.deviceToken,
            deviceTokenExpiresAt: ISO8601.date(from: complete.deviceTokenExpiresAt),
            deviceId: complete.deviceId,
            capability: complete.capability,
            orgSlug: complete.orgSlug,
            orgKind: complete.orgKind,
            apiBase: endpoint.base.absoluteString)

        guard DeviceIdentityStore.store(record) else {
            return .failure(.keychainWriteFailed)
        }
        return .success(Result(record: record, userId: complete.userId))
    }
}

// MARK: - Enrollment link parsing

/// A parsed enrollment code + the API base to redeem it against. Accepts:
///  - a full `bromure://enroll?v=1&code=<code>&api=<url-encoded base>` deep link,
///  - an `https://…?code=…&api=…` universal link,
///  - a bare code string (redeemed against the app's default control plane).
struct EnrollLink: Equatable {
    let code: String
    let apiBase: String

    /// The app's control plane when a code carries no `api` of its own — the
    /// same default the managed-profile enrollment uses.
    static let defaultAPIBase = "https://bromure.io/api"

    init(code: String, apiBase: String) {
        self.code = code
        self.apiBase = apiBase
    }

    init?(parsing raw: String) {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        // A URL (custom scheme or https) with a `code` query item.
        if s.contains("://"), let comps = URLComponents(string: s) {
            let host = comps.host?.lowercased()
            let path = comps.path.lowercased()
            let looksLikeEnroll = host == "enroll" || path.contains("enroll") || comps.scheme == "bromure"
            let items = comps.queryItems ?? []
            if looksLikeEnroll, let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty {
                let api = items.first(where: { $0.name == "api" })?.value
                self.init(code: code, apiBase: api?.isEmpty == false ? api! : EnrollLink.defaultAPIBase)
                return
            }
            return nil
        }

        // A bare code (no whitespace, base64url-ish). Redeem against the default.
        guard s.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              s.count >= 16,
              s.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        else { return nil }
        self.init(code: s, apiBase: EnrollLink.defaultAPIBase)
    }
}
