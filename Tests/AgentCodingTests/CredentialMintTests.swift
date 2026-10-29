import Foundation
import Testing
@testable import bromure_ac

/// Board: "Live credential generation should be swapped", and the audit it
/// quotes: "The AWS re-signer signs sts:GetSessionToken/GetFederationToken …
/// and AssumeRole …, and relays the STS response into the VM unscrubbed. A
/// hostile guest with any AWS-credentialed workspace mints itself real
/// temporary keys." doctl does the same with registry, cluster and Spaces
/// credentials. The proxy now hands the VM fakes for whatever such a call
/// issues, keeps the real values in the workspace, and swaps or re-signs
/// with them; a call whose secret can't be faked is refused.
@Suite("Minted credentials: the VM gets fakes, the host keeps the real ones")
struct CredentialMintTests {
    private static let salt = Data(repeating: 7, count: 32)

    private static func request(_ method: String, _ target: String, headers: [String] = [], body: String = "") -> Data {
        var head = "\(method) \(target) HTTP/1.1\r\nHost: x\r\n"
        for h in headers { head += h + "\r\n" }
        head += "Content-Length: \(body.utf8.count)\r\n\r\n"
        return Data((head + body).utf8)
    }
    private static let sigv4 = "Authorization: AWS4-HMAC-SHA256 Credential=AKIAPRIMARY/20261024/us-east-1/%@/aws4_request, SignedHeaders=host, Signature=00"
    private static func signed(_ service: String) -> String { String(format: sigv4, service) }
    private static let form = "Content-Type: application/x-www-form-urlencoded; charset=utf-8"

    // MARK: Classification

    @Test("the calls that issue a credential are recognised, on every protocol AWS uses")
    func classify() {
        func c(_ raw: Data, _ host: String) -> CredentialMint.Classification? { CredentialMint.classify(rawRequest: raw, host: host) }
        #expect(c(Self.request("POST", "/", headers: [Self.signed("sts"), Self.form], body: "Action=AssumeRole&Version=2011-06-15&RoleArn=arn"),
                  "sts.amazonaws.com") == .mint(.awsTemporary(action: "sts:AssumeRole")))
        #expect(c(Self.request("GET", "/?Action=GetSessionToken&Version=2011-06-15", headers: [Self.signed("sts")]),
                  "sts.us-east-1.amazonaws.com") == .mint(.awsTemporary(action: "sts:GetSessionToken")))
        #expect(c(Self.request("POST", "/", headers: [Self.signed("sts"), "X-Amz-Target: AWSSecurityTokenServiceV20110615.GetFederationToken"]),
                  "sts.amazonaws.com") == .mint(.awsTemporary(action: "sts:GetFederationToken")))
        #expect(c(Self.request("POST", "/", headers: [Self.signed("iam"), Self.form], body: "Action=CreateAccessKey&UserName=bob"),
                  "iam.amazonaws.com") == .mint(.awsAccessKey))
        #expect(c(Self.request("GET", "/federation/credentials?role_name=r&account_id=1"), "portal.sso.us-east-1.amazonaws.com")
                == .mint(.awsTemporary(action: "sso:GetRoleCredentials")))
        #expect(c(Self.request("POST", "/", headers: ["X-Amz-Target: AWSCognitoIdentityService.GetCredentialsForIdentity"]),
                  "cognito-identity.us-east-1.amazonaws.com") == .mint(.awsTemporary(action: "cognito-identity:GetCredentialsForIdentity")))
        #expect(c(Self.request("POST", "/", headers: [Self.signed("ecr"), "X-Amz-Target: AmazonEC2ContainerRegistry_V20150921.GetAuthorizationToken"]),
                  "api.ecr.us-east-1.amazonaws.com") == .mint(.ecrToken(action: "ecr:GetAuthorizationToken")))
        // A password the guest chose: nothing to fake, refused.
        #expect(c(Self.request("POST", "/", headers: [Self.signed("iam"), Self.form], body: "Action=CreateLoginProfile&UserName=bob&Password=x"),
                  "iam.amazonaws.com") == .deny(action: "iam:CreateLoginProfile"))
        // No way around it: case, a second Action, a FIPS host, an untyped body.
        #expect(c(Self.request("POST", "/", headers: [Self.signed("sts"), Self.form], body: "action=assumerole"),
                  "sts.amazonaws.com") == .mint(.awsTemporary(action: "sts:AssumeRole")))
        #expect(c(Self.request("POST", "/?Action=GetCallerIdentity", headers: [Self.signed("sts"), Self.form], body: "Action=AssumeRole"),
                  "sts.amazonaws.com") == .mint(.awsTemporary(action: "sts:AssumeRole")))
        #expect(c(Self.request("POST", "/", body: "Action=GetSessionToken"), "sts-fips.us-east-1.amazonaws.com")
                == .mint(.awsTemporary(action: "sts:GetSessionToken")))
        #expect(c(Self.request("POST", "/", headers: [Self.signed("iam")], body: "Action=CreateAccessKey&Action=ListUsers"),
                  "iam.amazonaws.com") == .mint(.awsAccessKey))
        #expect(c(Self.request("POST", "/", headers: [Self.signed("iam"), Self.form], body: "Action=createLoginProfile"),
                  "iam.amazonaws.com") == .deny(action: "iam:createLoginProfile"))
        // Dual-stack and other partitions' names for the same endpoints.
        #expect(c(Self.request("GET", "/federation/credentials?role_name=r&account_id=1"), "portal.sso.us-east-1.api.aws")
                == .mint(.awsTemporary(action: "sso:GetRoleCredentials")))
        #expect(c(Self.request("POST", "/", body: "Action=AssumeRoleWithWebIdentity"), "sts.us-east-1.api.aws")
                == .mint(.awsTemporary(action: "sts:AssumeRoleWithWebIdentity")))
        #expect(c(Self.request("POST", "/", body: "Action=AssumeRole"), "sts.us-iso-east-1.c2s.ic.gov")
                == .mint(.awsTemporary(action: "sts:AssumeRole")))
        #expect(c(Self.request("POST", "/", body: "Action=AssumeRole"), "sts.example.com") == nil)
        // Every partition's dual-stack name (botocore partitions.json): the
        // China portal and STS resolve to the same hosts as their
        // .amazonaws.com.cn names (Finding CWE-669).
        #expect(c(Self.request("GET", "/federation/credentials?role_name=r&account_id=1"),
                  "portal.sso.cn-north-1.api.amazonwebservices.com.cn") == .mint(.awsTemporary(action: "sso:GetRoleCredentials")))
        #expect(c(Self.request("POST", "/", body: "Action=AssumeRoleWithWebIdentity"), "sts.cn-north-1.api.amazonwebservices.com.cn")
                == .mint(.awsTemporary(action: "sts:AssumeRoleWithWebIdentity")))
        for host in ["sts.eusc-de-east-1.api.amazonwebservices.eu", "sts.us-iso-east-1.api.aws.ic.gov",
                     "sts.us-isob-east-1.api.aws.scloud", "sts.eu-isoe-west-1.api.cloud-aws.adc-e.uk",
                     "sts.us-isof-south-1.api.aws.hci.ic.gov", "sts.us-gov-west-1.api.aws"] {
            #expect(c(Self.request("POST", "/", body: "Action=AssumeRoleWithSAML"), host)
                    == .mint(.awsTemporary(action: "sts:AssumeRoleWithSAML")), "\(host)")
        }
        // Ordinary calls are left alone.
        #expect(c(Self.request("POST", "/", headers: [Self.signed("sts"), Self.form], body: "Action=GetCallerIdentity"), "sts.amazonaws.com") == nil)
        #expect(c(Self.request("GET", "/v2/droplets"), "api.digitalocean.com") == nil)
        // doctl
        #expect(c(Self.request("GET", "/v2/registry/docker-credentials?read_write=true"), "api.digitalocean.com") == .mint(.doRegistry))
        #expect(c(Self.request("GET", "/v2/kubernetes/clusters/abc/credentials"), "api.digitalocean.com") == .mint(.doKubeCredentials))
        #expect(c(Self.request("GET", "/v2/kubernetes/clusters/abc/kubeconfig"), "api.digitalocean.com") == .mint(.doKubeconfig))
        #expect(c(Self.request("POST", "/v2/spaces/keys", body: "{}"), "api.digitalocean.com") == .mint(.doSpacesKey))
    }

    // MARK: Rewriting

    static let stsXML = """
    <AssumeRoleResponse xmlns="https://sts.amazonaws.com/doc/2011-06-15/"><AssumeRoleResult>
      <Credentials>
        <AccessKeyId>ASIAMINTED000001</AccessKeyId>
        <SecretAccessKey>realSecret/With+Slash0000000000000000000</SecretAccessKey>
        <SessionToken>IQoJb3JpZ2luX2VjEREAL+TOKEN/abc==</SessionToken>
        <Expiration>2099-01-01T00:00:00Z</Expiration>
      </Credentials>
      <AssumedRoleUser><Arn>arn:aws:sts::1:assumed-role/r/s</Arn></AssumedRoleUser>
    </AssumeRoleResult></AssumeRoleResponse>
    """

    @Test("sts:AssumeRole: secret and session token replaced, access key id kept, the real ones minted")
    func stsXML() throws {
        let r = try CredentialMint.rewrite(body: Data(Self.stsXML.utf8), kind: .awsTemporary(action: "sts:AssumeRole"), salt: Self.salt)
        let out = String(decoding: r.body, as: UTF8.self)
        #expect(!out.contains("realSecret/With+Slash") && !out.contains("IQoJb3JpZ2luX2VjEREAL"))
        #expect(out.contains("<AccessKeyId>ASIAMINTED000001</AccessKeyId>"))
        #expect(out.contains("arn:aws:sts::1:assumed-role/r/s"))
        let m = try #require(r.minted.first)
        #expect(r.minted.count == 1 && m.kind == .sigV4 && m.accessKeyID == "ASIAMINTED000001")
        #expect(m.secret == "realSecret/With+Slash0000000000000000000" && m.sessionToken == "IQoJb3JpZ2luX2VjEREAL+TOKEN/abc==")
        #expect(m.expiresAt == ISO8601DateFormatter().date(from: "2099-01-01T00:00:00Z") && m.source == "sts:AssumeRole")
    }

    @Test("iam:CreateAccessKey: a long-lived key, kept with no expiry")
    func iamCreateAccessKey() throws {
        let xml = "<CreateAccessKeyResponse><CreateAccessKeyResult><AccessKey><UserName>bob</UserName><AccessKeyId>AKIANEWKEY000001</AccessKeyId><Status>Active</Status><SecretAccessKey>longLivedSecret000000000000000000000000</SecretAccessKey></AccessKey></CreateAccessKeyResult></CreateAccessKeyResponse>"
        let r = try CredentialMint.rewrite(body: Data(xml.utf8), kind: .awsAccessKey, salt: Self.salt)
        #expect(!String(decoding: r.body, as: UTF8.self).contains("longLivedSecret"))
        #expect(r.minted.map(\.accessKeyID) == ["AKIANEWKEY000001"] && r.minted[0].expiresAt == nil && r.minted[0].hosts.isEmpty)
    }

    @Test("SSO JSON, with the secret's slash JSON-escaped on the wire")
    func ssoEscaped() throws {
        let json = #"{"roleCredentials":{"accessKeyId":"ASIASSO000000001","secretAccessKey":"sso\/secret+0000000000000000000000000000","sessionToken":"ssoToken\/xyz","expiration":4070908800000}}"#
        let r = try CredentialMint.rewrite(body: Data(json.utf8), kind: .awsTemporary(action: "sso:GetRoleCredentials"), salt: Self.salt)
        let out = String(decoding: r.body, as: UTF8.self)
        #expect(!out.contains(#"sso\/secret"#) && !out.contains("sso/secret") && !out.contains("ssoToken"))
        let obj = try #require(try JSONSerialization.jsonObject(with: r.body) as? [String: [String: Any]])
        #expect(obj["roleCredentials"]?["accessKeyId"] as? String == "ASIASSO000000001")
        #expect(r.minted.first?.secret == "sso/secret+0000000000000000000000000000")
        #expect(r.minted.first?.expiresAt == Date(timeIntervalSince1970: 4070908800))
    }

    @Test("ecr:GetAuthorizationToken: docker login gets AWS:<fake>, swapped back on the registry")
    func ecr() async throws {
        let token = Data("AWS:realEcrPassword".utf8).base64EncodedString()
        let json = #"{"authorizationData":[{"authorizationToken":"\#(token)","expiresAt":4070908800,"proxyEndpoint":"https://123.dkr.ecr.us-east-1.amazonaws.com"}]}"#
        let r = try CredentialMint.rewrite(body: Data(json.utf8), kind: .ecrToken(action: "ecr:GetAuthorizationToken"), salt: Self.salt)
        let obj = try #require(try JSONSerialization.jsonObject(with: r.body) as? [String: [[String: Any]]])
        let fakeToken = try #require(obj["authorizationData"]?.first?["authorizationToken"] as? String)
        let decoded = String(decoding: try #require(Data(base64Encoded: fakeToken)), as: UTF8.self)
        let fake = MintedCredential.bearerFake(for: "realEcrPassword", salt: Self.salt)
        #expect(decoded == "AWS:\(fake)")
        #expect(r.minted.first?.hosts == ["123.dkr.ecr.us-east-1.amazonaws.com"])

        // The registry login the VM then makes.
        let swapper = TokenSwapper(consent: ConsentBroker()), pid = UUID()
        swapper.setMap(TokenMap(entries: MintedCredential.tokenEntries(r.minted, salt: Self.salt)), for: pid)
        let login = Self.request("GET", "/v2/", headers: ["Authorization: Basic \(fakeToken)"])
        let swapped = await swapper.swap(rawRequest: login, host: "123.dkr.ecr.us-east-1.amazonaws.com", profileID: pid)
        #expect(String(decoding: swapped.modified, as: UTF8.self).contains("Basic \(token)"))
        // Nowhere else.
        let elsewhere = await swapper.swap(rawRequest: login, host: "evil.example.com", profileID: pid)
        #expect(!String(decoding: elsewhere.modified, as: UTF8.self).contains(token))
    }

    @Test("doctl registry login: the docker auth carries the fake on both sides")
    func doRegistry() throws {
        let auth = Data("realDoToken:realDoToken\n".utf8).base64EncodedString()
        let json = #"{"auths":{"registry.digitalocean.com":{"auth":"\#(auth)"}}}"#
        let r = try CredentialMint.rewrite(body: Data(json.utf8), kind: .doRegistry, salt: Self.salt)
        let fake = MintedCredential.bearerFake(for: "realDoToken", salt: Self.salt)
        let obj = try #require(try JSONSerialization.jsonObject(with: r.body) as? [String: [String: [String: String]]])
        let out = try #require(obj["auths"]?["registry.digitalocean.com"]?["auth"])
        #expect(String(decoding: try #require(Data(base64Encoded: out)), as: UTF8.self) == "\(fake):\(fake)")
        #expect(r.minted.first?.hosts == ["registry.digitalocean.com"] && r.minted.first?.secret == "realDoToken")
    }

    @Test("doctl cluster credentials and kubeconfig: the token swapped for the cluster's API host")
    func doKube() throws {
        let creds = #"{"server":"https://abc.k8s.ondigitalocean.com","certificate_authority_data":"Q0E=","client_certificate_data":null,"client_key_data":null,"token":"realKubeToken","expires_at":"2099-11-09T11:50:28.889080521Z"}"#
        let r = try CredentialMint.rewrite(body: Data(creds.utf8), kind: .doKubeCredentials, salt: Self.salt)
        #expect(!String(decoding: r.body, as: UTF8.self).contains("realKubeToken"))
        #expect(r.minted.first?.hosts == ["abc.k8s.ondigitalocean.com"])
        #expect(r.minted.first?.expiresAt != nil)

        let yaml = """
        apiVersion: v1
        clusters:
        - cluster:
            certificate-authority-data: Q0E=
            server: https://abc.k8s.ondigitalocean.com
          name: c
        users:
        - name: c-admin
          user:
            token: realKubeconfigToken
        """
        let k = try CredentialMint.rewrite(body: Data(yaml.utf8), kind: .doKubeconfig, salt: Self.salt)
        let out = String(decoding: k.body, as: UTF8.self)
        #expect(!out.contains("realKubeconfigToken"))
        #expect(out.contains("token: \(MintedCredential.bearerFake(for: "realKubeconfigToken", salt: Self.salt))"))

        // A client key can't be faked: refused, not passed on.
        let keyed = creds.replacingOccurrences(of: #""client_key_data":null"#, with: #""client_key_data":"S0VZ""#)
        #expect(throws: CredentialMint.RewriteError.self) {
            try CredentialMint.rewrite(body: Data(keyed.utf8), kind: .doKubeCredentials, salt: Self.salt)
        }
    }

    @Test("doctl spaces keys create: a SigV4 key for the Spaces hosts")
    func doSpaces() throws {
        let json = #"{"key":{"name":"k","grants":[],"access_key":"DO00SPACESKEY0001","secret_key":"realSpacesSecret00000000000000000000000","created_at":"2026-10-24T00:00:00Z"}}"#
        let r = try CredentialMint.rewrite(body: Data(json.utf8), kind: .doSpacesKey, salt: Self.salt)
        #expect(!String(decoding: r.body, as: UTF8.self).contains("realSpacesSecret"))
        #expect(r.minted.first?.kind == .sigV4 && r.minted.first?.hosts == ["digitaloceanspaces.com"])
        #expect(r.minted.first?.accessKeyID == "DO00SPACESKEY0001")
    }

    @Test("a success it can't rewrite is never passed on; an error passes, Content-Length follows the body")
    func failClosed() throws {
        func resp(_ status: String, _ body: String) -> Data {
            Data("HTTP/1.1 \(status)\r\nContent-Type: text/xml\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8)
        }
        let garbled = resp("200 OK", "<AssumeRoleResponse><weird>realSecret</weird></AssumeRoleResponse>")
        let (out, minted) = CredentialMint.rewriteResponse(garbled, kind: .awsTemporary(action: "sts:AssumeRole"), salt: Self.salt)
        #expect(minted.isEmpty)
        #expect(String(decoding: out, as: UTF8.self).hasPrefix("HTTP/1.1 502"))
        #expect(!String(decoding: out, as: UTF8.self).contains("realSecret"))

        let denied = resp("403 Forbidden", "<ErrorResponse><Error><Code>AccessDenied</Code></Error></ErrorResponse>")
        #expect(CredentialMint.rewriteResponse(denied, kind: .awsTemporary(action: "sts:AssumeRole"), salt: Self.salt).response == denied)

        let (ok, m) = CredentialMint.rewriteResponse(resp("200 OK", Self.stsXML), kind: .awsTemporary(action: "sts:AssumeRole"), salt: Self.salt)
        let text = String(decoding: ok, as: UTF8.self)
        let body = text.components(separatedBy: "\r\n\r\n").dropFirst().joined(separator: "\r\n\r\n")
        #expect(m.count == 1 && text.contains("Content-Length: \(body.utf8.count)\r\n"))
    }

    // MARK: Using the minted keys

    @Test("the re-signer signs with the minted key the guest used, with the real session token")
    func resignsWithMinted() async throws {
        let server = AWSCredentialServer(consent: ConsentBroker()), pid = UUID()
        server.setCredentials(AWSCredentials(accessKeyID: "AKIAPRIMARY", secretAccessKey: "primarySecret", region: "us-east-1"), for: pid)
        let r = try CredentialMint.rewrite(body: Data(Self.stsXML.utf8), kind: .awsTemporary(action: "sts:AssumeRole"), salt: Self.salt)
        r.minted.forEach { server.addMinted($0, for: pid) }
        let resigner = AWSResigner(credServer: server)

        let guest = Self.request("GET", "/?Action=ListBuckets", headers: [
            "Authorization: AWS4-HMAC-SHA256 Credential=ASIAMINTED000001/20261024/us-east-1/s3/aws4_request, SignedHeaders=host, Signature=00",
            "X-Amz-Security-Token: BromureStandInFAKE"])
        guard case .resigned(let bytes) = await resigner.resign(rawRequest: guest, host: "s3.amazonaws.com", profileID: pid) else {
            Issue.record("not resigned"); return
        }
        let out = String(decoding: bytes, as: UTF8.self)
        #expect(out.contains("Credential=ASIAMINTED000001/"))
        #expect(out.contains("X-Amz-Security-Token: IQoJb3JpZ2luX2VjEREAL+TOKEN/abc=="))
        #expect(!out.contains("BromureStandInFAKE"))

        // Any other key id still signs as the workspace (an SSO key cached
        // before a refresh, say).
        let other = Self.request("GET", "/", headers: [Self.signed("s3")])
        guard case .resigned(let p) = await resigner.resign(rawRequest: other, host: "s3.amazonaws.com", profileID: pid) else {
            Issue.record("not resigned"); return
        }
        #expect(String(decoding: p, as: UTF8.self).contains("Credential=AKIAPRIMARY/"))
    }

    @Test("one AWS host test: the resigner, the guardrail and the rewrite agree on every partition name")
    func oneHostTest() async {
        for suffix in AWSResigner.partitionDNSSuffixes {
            let host = "sts.region-1.\(suffix)"
            #expect(AWSResigner.isAWSHost(host) && GuardrailsConfig.isAWSHost(host) && CredentialMint.isAWSFamilyHost(host), "\(host)")
        }
        #expect(!AWSResigner.isAWSHost("evil-amazonaws.com") && !AWSResigner.isAWSHost("api.aws.evil.com"))
        // A dual-stack call is re-signed, so the workspace key works there --
        // and the read-only guardrail sees it.
        let server = AWSCredentialServer(consent: ConsentBroker()), pid = UUID()
        server.setCredentials(AWSCredentials(accessKeyID: "AKIAPRIMARY", secretAccessKey: "primarySecret"), for: pid)
        guard case .resigned = await AWSResigner(credServer: server).resign(
            rawRequest: Self.request("GET", "/", headers: [Self.signed("dynamodb")]),
            host: "dynamodb.us-east-1.api.aws", profileID: pid) else {
            Issue.record("dual-stack call not re-signed"); return
        }
        let g = GuardrailsConfig(kubernetes: .off, kubeHosts: [], aws: .readOnly)
        #expect(g.awsBlockReason(host: "dynamodb.us-east-1.api.aws", method: "POST",
                                 amzTarget: "DynamoDB_20120810.DeleteTable", formAction: nil) != nil)
    }

    @Test("an expired minted key is refused, never signed as the workspace's own")
    func expired() async {
        let server = AWSCredentialServer(consent: ConsentBroker()), pid = UUID()
        server.setCredentials(AWSCredentials(accessKeyID: "AKIAPRIMARY", secretAccessKey: "primarySecret"), for: pid)
        server.addMinted(MintedCredential(kind: .sigV4, source: "sts:AssumeRole", accessKeyID: "ASIAOLD",
                                          secret: "s", sessionToken: "t", expiresAt: Date(timeIntervalSinceNow: -60)), for: pid)
        let guest = Self.request("GET", "/", headers: [
            "Authorization: AWS4-HMAC-SHA256 Credential=ASIAOLD/20261024/us-east-1/s3/aws4_request, SignedHeaders=host, Signature=00"])
        guard case .denied(let resp) = await AWSResigner(credServer: server).resign(rawRequest: guest, host: "s3.amazonaws.com", profileID: pid) else {
            Issue.record("expected a refusal"); return
        }
        #expect(String(decoding: resp, as: UTF8.self).contains("expired"))
    }

    @Test("a Spaces key re-signs on DigitalOcean's hosts, and only its own")
    func spacesResign() async {
        let server = AWSCredentialServer(consent: ConsentBroker()), pid = UUID()
        server.addMinted(MintedCredential(kind: .sigV4, source: "DigitalOcean Spaces key", hosts: ["digitaloceanspaces.com"],
                                          accessKeyID: "DO00SPACES", secret: "spacesSecret"), for: pid)
        let resigner = AWSResigner(credServer: server)
        let guest = Self.request("GET", "/", headers: [
            "Authorization: AWS4-HMAC-SHA256 Credential=DO00SPACES/20261024/nyc3/s3/aws4_request, SignedHeaders=host, Signature=00"])
        guard case .resigned = await resigner.resign(rawRequest: guest, host: "bucket.nyc3.digitaloceanspaces.com", profileID: pid) else {
            Issue.record("not resigned"); return
        }
        guard case .unchanged = await resigner.resign(rawRequest: guest, host: "evil.example.com", profileID: pid) else {
            Issue.record("signed for a host the key isn't for"); return
        }
        #expect(server.hasMintedHost("bucket.nyc3.digitaloceanspaces.com", profileID: pid))
    }

    // MARK: Keeping them

    @Test("saved with the workspace: secrets go to the encrypted blob and come back")
    func persistence() throws {
        var p = Profile(name: "ws", tool: .claude, authMode: .token)
        let m = MintedCredential(kind: .sigV4, source: "sts:AssumeRole", accessKeyID: "ASIAX",
                                 secret: "realSecret", sessionToken: "realToken", expiresAt: Date(timeIntervalSince1970: 4070908800))
        p.mintedCredentials = [m]
        var stripped = p
        let secrets = ProfileSecrets.extract(stripping: &stripped)
        let json = String(decoding: try JSONEncoder().encode(stripped), as: UTF8.self)
        #expect(!json.contains("realSecret") && !json.contains("realToken") && json.contains("ASIAX"))
        var back = try JSONDecoder().decode(Profile.self, from: try JSONEncoder().encode(stripped))
        secrets.apply(to: &back)
        #expect(back.mintedCredentials == [m])
    }

    @Test("long-expired credentials are dropped; expired bearer tokens aren't swapped")
    func pruneAndEntries() {
        let now = Date()
        let fresh = MintedCredential(kind: .bearer, source: "a", hosts: ["h"], secret: "x")
        let recent = MintedCredential(kind: .bearer, source: "b", hosts: ["h"], secret: "y", expiresAt: now.addingTimeInterval(-60))
        let old = MintedCredential(kind: .bearer, source: "c", hosts: ["h"], secret: "z",
                                   expiresAt: now.addingTimeInterval(-MintedCredential.retentionAfterExpiry - 60))
        #expect(MintedCredential.pruned([fresh, recent, old], now: now).map(\.source) == ["a", "b"])
        #expect(MintedCredential.tokenEntries([fresh, recent], salt: Self.salt, now: now).map(\.real) == ["x"])
    }

    @Test("a save from an older copy (editor, remote edit, AppleScript) keeps what the VM minted since")
    func savesKeepMinted() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let app = try String(contentsOf: root.appendingPathComponent("Sources/AgentCoding/BromureAC.swift"), encoding: .utf8)
        let script = try String(contentsOf: root.appendingPathComponent("Sources/AgentCoding/ScriptCommands.swift"), encoding: .utf8)
        // The editor: the app's current list, before saveEdited writes the secrets blob.
        let persist = try #require(app.range(of: "func persistEditedProfile("))
        let body = app[persist.upperBound...]
        let carry = try #require(body.range(of: "profile.mintedCredentials = current.mintedCredentials"))
        let save = try #require(body.range(of: "try store.saveEdited(&profile)"))
        #expect(carry.lowerBound < save.lowerBound)
        // The document round-trips: the stored list, never the document's.
        #expect(app.components(separatedBy: "incoming.mintedCredentials = existing.mintedCredentials").count == 2)
        #expect(script.contains("incoming.mintedCredentials = existing.mintedCredentials"))
    }

    @Test("the proxy refuses or rewrites before anything reaches the VM")
    func wiring() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/AgentCoding/Mitm/HTTPProxy.swift"), encoding: .utf8)
        let classify = try #require(src.range(of: "switch CredentialMint.classify(rawRequest: swap.modified, host: host)"))
        let resign = try #require(src.range(of: "await awsResigner.resign("))
        #expect(classify.lowerBound < resign.lowerBound)
        #expect(src.contains("rewrite: { minter.process(response: $0, kind: mintKind, profileID: pid) })"))
        let relay = try #require(src.range(of: "if let mintKind, let minter {"))
        let streaming = try #require(src.range(of: "relay = try await relayUpstream(rawRequest: toForward,"))
        #expect(relay.lowerBound < streaming.lowerBound)
    }
}
