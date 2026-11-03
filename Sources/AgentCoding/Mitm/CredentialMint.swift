import Foundation

// MARK: - Credentials the guest mints through the proxy

// `MintedCredential` itself is in MintedCredential.swift (shared with the
// iOS client, which reads workspace configurations).

extension MintedCredential {
    /// Token-map entries for the workspace's live bearer credentials.
    public static func tokenEntries(_ minted: [MintedCredential], salt: Data,
                                    now: Date = Date()) -> [TokenMap.Entry] {
        minted.filter { $0.kind == .bearer && !$0.secret.isEmpty && !$0.isExpired(at: now) }
            .flatMap { m -> [TokenMap.Entry] in
                let fake = bearerFake(for: m.secret, salt: salt)
                return m.hosts.map {
                    TokenMap.Entry(fake: fake, real: m.secret, host: $0,
                                   consentDisplayName: m.source)
                }
            }
    }
}

/// Recognises the requests that make an API issue a credential, and
/// rewrites the response so the VM gets fakes and the host keeps the real
/// values (Finding: "Live credential generation should be swapped"; the
/// audit's "the AWS re-signer signs sts:GetSessionToken … and relays the
/// STS response into the VM unscrubbed"). A response it can't rewrite
/// completely is never passed on: the guest gets a 502 instead.
public enum CredentialMint {
    public enum Kind: Equatable, Sendable {
        /// STS / SSO / Cognito temporary credentials: access key, secret,
        /// session token, expiry. `action` is "sts:AssumeRole" etc.
        case awsTemporary(action: String)
        /// iam:CreateAccessKey: a long-lived access key pair.
        case awsAccessKey
        /// ecr(-public):GetAuthorizationToken: base64 "AWS:<password>"
        /// for `docker login`.
        case ecrToken(action: String)
        /// GET /v2/registry/docker-credentials: docker config with base64
        /// "<token>:<token>" for registry.digitalocean.com.
        case doRegistry
        /// GET /v2/kubernetes/clusters/{id}/credentials: JSON with `token`.
        case doKubeCredentials
        /// GET /v2/kubernetes/clusters/{id}/kubeconfig: YAML with `token:`.
        case doKubeconfig
        /// POST /v2/spaces/keys: an S3-compatible access key pair.
        case doSpacesKey
    }

    public enum Classification: Equatable, Sendable {
        case mint(Kind)
        /// Issues a credential no fake can stand in for (a console password
        /// the guest chose, a service-specific password): refused.
        case deny(action: String)
    }

    /// AWS calls that hand back a secret chosen by, or readable to, the
    /// caller with nothing for the host to swap -- refused outright, in
    /// every guardrail mode.
    static let awsDenied: Set<String> = [
        "iam:CreateLoginProfile", "iam:UpdateLoginProfile",
        "iam:CreateServiceSpecificCredential", "iam:ResetServiceSpecificCredential",
    ]
    static let stsTemporary: Set<String> = [
        "AssumeRole", "AssumeRoleWithSAML", "AssumeRoleWithWebIdentity",
        "GetSessionToken", "GetFederationToken", "AssumeRoot",
    ]

    // MARK: Classification

    public static func classify(rawRequest: Data, host: String) -> Classification? {
        guard let p = ParsedHTTPRequest(rawRequest: rawRequest) else { return nil }
        return classify(method: p.method, host: host, path: p.path, query: p.query,
                        headers: p.headers, body: p.body)
    }

    static func classify(method: String, host: String, path: String, query: String,
                         headers: [(String, String)], body: Data) -> Classification? {
        let h = host.lowercased()
        if h == "api.digitalocean.com" {
            return classifyDigitalOcean(method: method.uppercased(), path: path)
        }
        guard isAWSFamilyHost(h) else { return nil }
        // Every action the request names (target header, query, form body):
        // whichever one AWS acts on, a refusal or a rewrite covers it.
        let actions = awsActions(host: h, method: method, path: path, query: query,
                                 headers: headers, body: body)
        if let denied = actions.first(where: { a in awsDenied.contains { $0.caseInsensitiveCompare(a) == .orderedSame } }) {
            return .deny(action: denied)
        }
        for action in actions {
            let parts = action.split(separator: ":", maxSplits: 1).map { $0.lowercased() }
            guard parts.count == 2 else { continue }
            let canonical = { (name: String) in "\(parts[0]):\(name)" }
            switch (parts[0], parts[1]) {
            case ("sts", let a):
                if let name = stsTemporary.first(where: { $0.lowercased() == a }) {
                    return .mint(.awsTemporary(action: canonical(name)))
                }
            case ("sso", "getrolecredentials"): return .mint(.awsTemporary(action: canonical("GetRoleCredentials")))
            case ("cognito-identity", "getcredentialsforidentity"):
                return .mint(.awsTemporary(action: canonical("GetCredentialsForIdentity")))
            case ("iam", "createaccesskey"): return .mint(.awsAccessKey)
            case ("ecr", "getauthorizationtoken"), ("ecr-public", "getauthorizationtoken"):
                return .mint(.ecrToken(action: canonical("GetAuthorizationToken")))
            default: break
            }
        }
        return nil
    }

    private static func classifyDigitalOcean(method: String, path: String) -> Classification? {
        let segs = path.split(separator: "/").map(String.init)
        // /v2/registry/docker-credentials, /v2/registries/{name}/docker-credentials
        if method == "GET", segs.count >= 3, segs[0] == "v2",
           segs[1] == "registry" || segs[1] == "registries", segs.last == "docker-credentials" {
            return .mint(.doRegistry)
        }
        // /v2/kubernetes/clusters/{id}/credentials | /kubeconfig
        if method == "GET", segs.count == 5, segs[0] == "v2", segs[1] == "kubernetes", segs[2] == "clusters" {
            if segs[4] == "credentials" { return .mint(.doKubeCredentials) }
            if segs[4] == "kubeconfig" { return .mint(.doKubeconfig) }
        }
        if method == "POST", segs == ["v2", "spaces", "keys"] { return .mint(.doSpacesKey) }
        return nil
    }

    /// Every name an AWS endpoint answers on: the resigner's partition table
    /// (each partition's IPv4 and dual-stack suffix --
    /// `portal.sso.cn-north-1.api.amazonwebservices.com.cn` is the same
    /// portal as `….amazonaws.com.cn`), plus ECR Public. A credential issued
    /// on any of them is rewritten.
    static func isAWSFamilyHost(_ host: String) -> Bool {
        let h = host.lowercased()
        return AWSResigner.isAWSHost(h) || h == "public.ecr.aws"
    }

    /// "service:Action" for an AWS request: the JSON protocol's
    /// `X-Amz-Target`, the query protocol's `Action=` (form body or query
    /// string), or the SSO portal's REST path. The service comes from the
    /// SigV4 scope when signed, else the host.
    static func awsAction(host: String, method: String, path: String, query: String,
                          headers: [(String, String)], body: Data) -> String? {
        awsActions(host: host, method: method, path: path, query: query, headers: headers, body: body).first
    }

    /// Every "service:Action" a request names, the target header first.
    static func awsActions(host: String, method: String, path: String, query: String,
                           headers: [(String, String)], body: Data) -> [String] {
        func header(_ n: String) -> String? {
            headers.first { $0.0.lowercased() == n }?.1
        }
        if host.hasPrefix("portal.sso.") {
            return path.lowercased().hasSuffix("/federation/credentials") ? ["sso:GetRoleCredentials"] : []
        }
        let service: String = {
            if let auth = header("authorization"), let scope = AWSResigner.parseScope(auth) {
                return scope.service
            }
            if host == "public.ecr.aws" || host.hasPrefix("api.ecr-public.") { return "ecr-public" }
            // sts-fips.us-east-1…, api.ecr.… → sts, ecr.
            let first = host.split(separator: ".").first.map(String.init) ?? ""
            let label = first == "api" ? (host.split(separator: ".").dropFirst().first.map(String.init) ?? "") : first
            return label.hasSuffix("-fips") ? String(label.dropLast(5)) : label
        }().lowercased()
        var out: [String] = []
        if let target = header("x-amz-target"), let dot = target.lastIndex(of: ".") {
            let action = String(target[target.index(after: dot)...])
            let prefix = target[..<dot].lowercased()
            let svc: String
            if prefix.hasPrefix("awssecuritytokenservice") { svc = "sts" }
            else if prefix.hasPrefix("awscognitoidentityservice") { svc = "cognito-identity" }
            else if prefix.hasPrefix("amazonec2containerregistry") { svc = "ecr" }
            else if prefix.hasPrefix("spencerfrontendservice") { svc = "ecr-public" }
            else { svc = service }
            out.append("\(svc):\(action)")
        }
        guard !service.isEmpty else { return out }
        // Any body that parses as a form, whatever its declared type.
        for form in [query, String(decoding: body, as: UTF8.self)] {
            for action in formValues("Action", in: form) where !action.isEmpty {
                out.append("\(service):\(action)")
            }
        }
        return out
    }

    private static func formValues(_ name: String, in form: String) -> [String] {
        form.split(separator: "&").compactMap { pair in
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2,
                  kv[0].replacingOccurrences(of: "+", with: " ").removingPercentEncoding?
                    .caseInsensitiveCompare(name) == .orderedSame else { return nil }
            return kv[1].replacingOccurrences(of: "+", with: " ").removingPercentEncoding?
                .trimmingCharacters(in: .whitespaces)
        }
    }

    // MARK: Rewriting the response

    public struct Rewrite {
        public var body: Data
        public var minted: [MintedCredential]
    }

    public enum RewriteError: Error, Equatable {
        /// A success response whose credentials couldn't all be found and
        /// replaced; passing it on would hand the VM a real secret.
        case unrecognised(String)
    }

    /// Replace every credential in a success body with a fake. Throws when
    /// it can't account for one (fail closed: the caller answers 502).
    public static func rewrite(body: Data, kind: Kind, salt: Data,
                               now: Date = Date()) throws -> Rewrite {
        var text = String(decoding: body, as: UTF8.self)
        var minted: [MintedCredential] = []
        var reals: [String] = []

        func swapIn(_ real: String, _ fake: String) throws {
            guard !real.isEmpty else { return }
            let before = text
            for (r, f) in [(real, fake), (jsonEscaped(real), jsonEscaped(fake))] where r != f {
                text = text.replacingOccurrences(of: r, with: f)
            }
            if text == before { throw RewriteError.unrecognised("credential value not found in the body") }
            reals.append(real)
        }

        switch kind {
        case .awsTemporary(let action):
            let sets = awsKeySets(text)
            guard !sets.isEmpty else { throw RewriteError.unrecognised("no credentials in the \(action) response") }
            for s in sets {
                guard !s.secret.isEmpty, !s.sessionToken.isEmpty else {
                    throw RewriteError.unrecognised("incomplete credentials in the \(action) response")
                }
                try swapIn(s.secret, fakeSecret())
                try swapIn(s.sessionToken, fakeSessionToken())
                minted.append(MintedCredential(kind: .sigV4, source: action, accessKeyID: s.accessKeyID,
                                               secret: s.secret, sessionToken: s.sessionToken,
                                               createdAt: now, expiresAt: s.expiration))
            }
        case .awsAccessKey, .doSpacesKey:
            let source = kind == .awsAccessKey ? "iam:CreateAccessKey" : "DigitalOcean Spaces key"
            let sets = awsKeySets(text)
            guard !sets.isEmpty else { throw RewriteError.unrecognised("no access key in the \(source) response") }
            for s in sets {
                guard !s.secret.isEmpty else { throw RewriteError.unrecognised("no secret in the \(source) response") }
                try swapIn(s.secret, fakeSecret())
                minted.append(MintedCredential(kind: .sigV4, source: source,
                                               hosts: kind == .doSpacesKey ? ["digitaloceanspaces.com"] : [],
                                               accessKeyID: s.accessKeyID, secret: s.secret,
                                               createdAt: now, expiresAt: s.expiration))
            }
        case .ecrToken(let action):
            guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let data = obj["authorizationData"] as? [[String: Any]], !data.isEmpty else {
                throw RewriteError.unrecognised("no authorizationData in the \(action) response")
            }
            for d in data {
                guard let token = d["authorizationToken"] as? String,
                      let decoded = Data(base64Encoded: token).map({ String(decoding: $0, as: UTF8.self) }),
                      let colon = decoded.firstIndex(of: ":") else {
                    throw RewriteError.unrecognised("unreadable authorizationToken in the \(action) response")
                }
                let password = String(decoded[decoded.index(after: colon)...])
                let fake = MintedCredential.bearerFake(for: password, salt: salt)
                let fakeToken = Data((decoded[..<colon] + ":" + fake).utf8).base64EncodedString()
                try swapIn(token, fakeToken)
                // The registry endpoint docker logs in to; ecr-public's is
                // public.ecr.aws.
                let endpoint = (d["proxyEndpoint"] as? String).flatMap { URL(string: $0)?.host }
                    ?? (action.hasPrefix("ecr-public") ? "public.ecr.aws" : nil)
                guard let endpoint else { throw RewriteError.unrecognised("no proxyEndpoint in the \(action) response") }
                reals.append(password)
                minted.append(MintedCredential(kind: .bearer, source: action, hosts: [endpoint],
                                               secret: password, createdAt: now,
                                               expiresAt: epochDate(d["expiresAt"])))
            }
        case .doRegistry:
            guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let auths = obj["auths"] as? [String: Any], !auths.isEmpty else {
                throw RewriteError.unrecognised("no auths in the registry credentials")
            }
            for (registry, value) in auths {
                guard let auth = (value as? [String: Any])?["auth"] as? String,
                      let decoded = Data(base64Encoded: auth.trimmingCharacters(in: .whitespacesAndNewlines))
                        .map({ String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .newlines) }),
                      let colon = decoded.firstIndex(of: ":") else {
                    throw RewriteError.unrecognised("unreadable auth for \(registry)")
                }
                let user = String(decoded[..<colon]), password = String(decoded[decoded.index(after: colon)...])
                let fake = MintedCredential.bearerFake(for: password, salt: salt)
                // DigitalOcean's user is the token too.
                let fakeUser = user == password ? fake : user
                try swapIn(auth, Data("\(fakeUser):\(fake)".utf8).base64EncodedString())
                reals.append(password)
                minted.append(MintedCredential(kind: .bearer, source: "DigitalOcean registry token",
                                               hosts: [registry], secret: password, createdAt: now))
            }
        case .doKubeCredentials:
            guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                throw RewriteError.unrecognised("unreadable cluster credentials")
            }
            if let key = obj["client_key_data"] as? String, !key.isEmpty {
                throw RewriteError.unrecognised("the cluster issued a client key, which can't be swapped")
            }
            guard let token = obj["token"] as? String, !token.isEmpty,
                  let server = (obj["server"] as? String).flatMap({ URL(string: $0)?.host }) else {
                throw RewriteError.unrecognised("no token or server in the cluster credentials")
            }
            try swapIn(token, MintedCredential.bearerFake(for: token, salt: salt))
            minted.append(MintedCredential(kind: .bearer, source: "DigitalOcean Kubernetes token",
                                           hosts: [server], secret: token, createdAt: now,
                                           expiresAt: isoDate(obj["expires_at"])))
        case .doKubeconfig:
            if text.range(of: #"client-key-data:\s*\S"#, options: .regularExpression) != nil {
                throw RewriteError.unrecognised("the kubeconfig carries a client key, which can't be swapped")
            }
            let tokens = yamlValues(key: "token", in: text)
            let servers = yamlValues(key: "server", in: text).compactMap { URL(string: $0)?.host }
            guard !tokens.isEmpty, !servers.isEmpty else {
                throw RewriteError.unrecognised("no token or server in the kubeconfig")
            }
            for token in Set(tokens) {
                try swapIn(token, MintedCredential.bearerFake(for: token, salt: salt))
                minted.append(MintedCredential(kind: .bearer, source: "DigitalOcean Kubernetes token",
                                               hosts: Array(Set(servers)).sorted(), secret: token, createdAt: now))
            }
        }

        // Nothing real left, raw or JSON-escaped.
        for r in reals where text.contains(r) || text.contains(jsonEscaped(r)) {
            throw RewriteError.unrecognised("a credential value is still in the body")
        }
        return Rewrite(body: Data(text.utf8), minted: minted)
    }

    /// Rewrite a whole buffered HTTP response (head + body, as
    /// `relayUpstreamCollecting` returns it). A non-2xx answer carries no
    /// credential and passes as is.
    public static func rewriteResponse(_ response: Data, kind: Kind, salt: Data,
                                       now: Date = Date()) -> (response: Data, minted: [MintedCredential]) {
        guard let sep = response.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: response.subdata(in: 0..<sep.lowerBound), encoding: .isoLatin1) else {
            return (refusal("the response couldn't be read"), [])
        }
        let status = head.split(separator: " ", maxSplits: 2).dropFirst().first.flatMap { Int($0) } ?? 0
        guard (200..<300).contains(status) else { return (response, []) }
        let body = response.subdata(in: sep.upperBound..<response.count)
        do {
            let r = try rewrite(body: body, kind: kind, salt: salt, now: now)
            var lines = head.components(separatedBy: "\r\n").filter {
                !$0.lowercased().hasPrefix("content-length:")
            }
            lines.append("Content-Length: \(r.body.count)")
            var out = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
            out.append(r.body)
            return (out, r.minted)
        } catch {
            let why = (error as? RewriteError).map { if case .unrecognised(let s) = $0 { return s }; return "" } ?? "\(error)"
            return (refusal(why), [])
        }
    }

    static func refusal(_ why: String) -> Data {
        let body = "Bromure: this request creates a credential, and Bromure couldn't replace it in the "
            + "response with a stand-in (\(why)). The response was not passed to the VM.\n"
        return httpResponse(status: 502, reason: "Bad Gateway", body: body)
    }

    static func denial(_ action: String) -> Data {
        let body = "Bromure: \(action) creates a credential the VM would hold in the clear "
            + "(a password it chose), which Bromure can't keep on the host. It is refused.\n"
        return httpResponse(status: 403, reason: "Forbidden", body: body)
    }

    private static func httpResponse(status: Int, reason: String, body: String) -> Data {
        let b = Data(body.utf8)
        var out = Data(("HTTP/1.1 \(status) \(reason)\r\nContent-Type: text/plain; charset=utf-8\r\n"
            + "Content-Length: \(b.count)\r\nConnection: close\r\n\r\n").utf8)
        out.append(b)
        return out
    }

    // MARK: Parsing helpers

    struct KeySet: Equatable {
        var accessKeyID: String
        var secret: String
        var sessionToken: String
        var expiration: Date?
    }

    /// Access key sets in an XML (query protocol) or JSON body, under any of
    /// the spellings AWS and DigitalOcean use.
    static func awsKeySets(_ text: String) -> [KeySet] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("<") {
            // One set per <Credentials> / <AccessKey> element.
            let blocks = xmlElements(["Credentials", "AccessKey"], in: trimmed)
            return blocks.compactMap { b in
                guard let akid = xmlValue("AccessKeyId", in: b) else { return nil }
                return KeySet(accessKeyID: akid,
                              secret: xmlValue("SecretAccessKey", in: b) ?? "",
                              sessionToken: xmlValue("SessionToken", in: b) ?? "",
                              expiration: isoDate(xmlValue("Expiration", in: b)))
            }
        }
        guard let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var out: [KeySet] = []
        func walk(_ v: Any) {
            if let d = v as? [String: Any] {
                func s(_ keys: [String]) -> String? {
                    for k in keys { if let x = d[k] as? String { return x } }
                    return nil
                }
                if let akid = s(["AccessKeyId", "accessKeyId", "access_key"]) {
                    let expRaw = d["Expiration"] ?? d["expiration"]
                    out.append(KeySet(accessKeyID: akid,
                                      secret: s(["SecretAccessKey", "secretAccessKey", "SecretKey", "secret_key"]) ?? "",
                                      sessionToken: s(["SessionToken", "sessionToken"]) ?? "",
                                      expiration: isoDate(expRaw) ?? epochDate(expRaw)))
                }
                d.values.forEach(walk)
            } else if let a = v as? [Any] {
                a.forEach(walk)
            }
        }
        walk(obj)
        return out
    }

    private static func xmlElements(_ names: [String], in text: String) -> [String] {
        var out: [String] = []
        for n in names {
            var rest = text[...]
            while let open = rest.range(of: "<\(n)>"), let close = rest.range(of: "</\(n)>", range: open.upperBound..<rest.endIndex) {
                out.append(String(rest[open.upperBound..<close.lowerBound]))
                rest = rest[close.upperBound...]
            }
        }
        return out
    }

    private static func xmlValue(_ name: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(name)>"),
              let close = text.range(of: "</\(name)>", range: open.upperBound..<text.endIndex) else { return nil }
        return String(text[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `key: value` lines in a YAML document, quotes stripped.
    static func yamlValues(key: String, in text: String) -> [String] {
        text.components(separatedBy: "\n").compactMap { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix(key + ":") else { return nil }
            let v = t.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return v.isEmpty ? nil : v
        }
    }

    private static func jsonEscaped(_ s: String) -> String {
        s.replacingOccurrences(of: "/", with: "\\/")
    }

    static func isoDate(_ v: Any?) -> Date? {
        guard let s = v as? String else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        // DigitalOcean's nanosecond fractions: drop them.
        if let dot = s.firstIndex(of: "."), let z = s.lastIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }), z > dot {
            return f.date(from: String(s[..<dot]) + String(s[z...]))
        }
        return nil
    }

    /// Epoch seconds (ECR, Cognito) or milliseconds (SSO).
    static func epochDate(_ v: Any?) -> Date? {
        guard let n = (v as? NSNumber)?.doubleValue, n > 0 else { return nil }
        return Date(timeIntervalSince1970: n > 1e11 ? n / 1000 : n)
    }

    /// A 40-character secret in AWS's alphabet: plausible to the SDK, which
    /// signs with it; the host discards that signature.
    static func fakeSecret() -> String {
        String((0..<40).map { _ in
            Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+/").randomElement()!
        })
    }

    /// Stands in for an STS session token. The host drops the guest's
    /// `X-Amz-Security-Token` and signs with the real one.
    static func fakeSessionToken() -> String {
        "BromureStandIn" + String((0..<120).map { _ in
            Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789").randomElement()!
        })
    }
}

/// The engine side: registers what a rewrite minted -- live in the token map
/// and the AWS credential server, then hands it to the app to save in the
/// workspace.
public final class CredentialMinter: @unchecked Sendable {
    private let salt: Data
    private let swapper: TokenSwapper
    private let awsCreds: AWSCredentialServer
    private let lock = NSLock()
    private var _sink: (@Sendable (UUID, MintedCredential) -> Void)?

    public init(salt: Data, swapper: TokenSwapper, awsCreds: AWSCredentialServer) {
        self.salt = salt
        self.swapper = swapper
        self.awsCreds = awsCreds
    }

    /// Where minted credentials go to be saved (set by the app).
    public var sink: (@Sendable (UUID, MintedCredential) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _sink }
        set { lock.lock(); _sink = newValue; lock.unlock() }
    }

    /// Rewrite a buffered response for `kind`, registering what it minted.
    public func process(response: Data, kind: CredentialMint.Kind, profileID: UUID) -> Data {
        let (out, minted) = CredentialMint.rewriteResponse(response, kind: kind, salt: salt)
        register(minted, for: profileID)
        let sink = self.sink
        for m in minted {
            FileHandle.standardError.write(Data(
                "[mitm] minted credential \(m.source) kept on the host (\(m.kind.rawValue), \(m.hosts.joined(separator: ",")))\n".utf8))
            BACEventEmitter.shared.emitDetached(
                profileID: profileID, eventType: "credential.minted",
                eventData: ["source": .string(m.source), "kind": .string(m.kind.rawValue),
                            "hosts": .string(m.hosts.joined(separator: ","))])
            sink?(profileID, m)
        }
        return out
    }

    /// Make minted credentials usable now, before (and regardless of) the
    /// save: the token map swaps the bearer fakes, the credential server
    /// signs for the SigV4 keys.
    public func register(_ minted: [MintedCredential], for profileID: UUID) {
        let entries = MintedCredential.tokenEntries(minted, salt: salt)
        if !entries.isEmpty { swapper.appendEntries(entries, for: profileID) }
        for m in minted where m.kind == .sigV4 { awsCreds.addMinted(m, for: profileID) }
    }
}
