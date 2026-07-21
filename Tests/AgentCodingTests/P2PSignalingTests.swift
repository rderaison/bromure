import Crypto
import Foundation
import Testing
@testable import bromure_ac

// Wire-facing P2P models. These lock the client to the exact bromure-infra
// contract (src/routes/devices.js, connections.js, device-channel.js) — a
// server-side field rename should break one of these, not ship silently.

@Suite("P2P signaling & candidates")
struct P2PSignalingTests {

    // MARK: Candidate priority

    @Test("candidate priority ranks host > srflx > port-mapped > relay")
    func candidatePriority() {
        let host = P2PCandidate(kind: .host, proto: .tcp, ip: "10.0.0.2", port: 2222)
        let srflx = P2PCandidate(kind: .srflx, proto: .tcp, ip: "1.2.3.4", port: 40000)
        let mapped = P2PCandidate(kind: .portMapped, proto: .tcp, ip: "1.2.3.4", port: 41000)
        let relay = P2PCandidate(kind: .relay, proto: .tcp, ip: "5.6.7.8", port: 3478)
        #expect(host.prio > srflx.prio)
        #expect(srflx.prio > mapped.prio)
        #expect(mapped.prio > relay.prio)
    }

    @Test("TCP outranks UDP within a kind")
    func tcpOverUdp() {
        let tcp = P2PCandidate(kind: .host, proto: .tcp, ip: "10.0.0.2", port: 2222)
        let udp = P2PCandidate(kind: .host, proto: .udp, ip: "10.0.0.2", port: 2222)
        #expect(tcp.prio > udp.prio)
    }

    // MARK: Host gathering

    @Test("host candidates never include loopback / link-local")
    func hostGather() {
        let cands = P2PCandidateGatherer.hostCandidates(sshPort: 2222)
        for c in cands {
            #expect(c.kind == .host)
            #expect(c.proto == .tcp)
            #expect(c.port == 2222)
            #expect(!c.ip.hasPrefix("127."))
            #expect(!c.ip.hasPrefix("169.254."))
            #expect(c.ip != "::1")
            #expect(!c.ip.lowercased().hasPrefix("fe80"))
        }
    }

    // MARK: Outgoing frame

    @Test("outgoing signal frame encodes the exact gateway shape")
    func outgoingFrame() throws {
        let payload = P2PSignalPayload(candidates: [
            P2PCandidate(kind: .host, proto: .tcp, ip: "10.0.0.2", port: 2222)
        ])
        let frame = OutgoingSignalFrame(connectionId: "conn-1", seq: 3, kind: .offer, payload: payload)
        let data = try frame.encoded()
        let obj = try #require((try JSONSerialization.jsonObject(with: data)) as? [String: Any])
        #expect(obj["connectionId"] as? String == "conn-1")
        #expect(obj["seq"] as? Int == 3)
        #expect(obj["kind"] as? String == "offer")
        #expect(obj["payload"] != nil)
    }

    @Test("oversized frame is rejected, not silently truncated")
    func frameTooLarge() {
        // Build a candidate list that blows past MAX_FRAME_BYTES (4096).
        let many = (0..<200).map {
            P2PCandidate(kind: .host, proto: .tcp, ip: "10.0.0.\($0 % 250)", port: 2222)
        }
        let frame = OutgoingSignalFrame(connectionId: "c", seq: 1, kind: .answer,
                                        payload: P2PSignalPayload(candidates: many))
        #expect(throws: P2PSignalError.self) { _ = try frame.encoded() }
    }

    // MARK: Incoming frames

    @Test("decode a relayed signal frame")
    func decodeSignal() throws {
        let json = """
        {"type":"signal","connectionId":"c1","seq":2,"kind":"candidate",
         "from":"peer-signal-id","payload":{"v":1,"candidate":{"kind":"host","proto":"tcp","ip":"10.0.0.5","port":2222,"prio":100}}}
        """
        let frame = try #require(IncomingServerFrame.decode(Data(json.utf8)))
        guard case .signal(let connId, let seq, let kind, let from, let payload) = frame else {
            Issue.record("expected signal"); return
        }
        #expect(connId == "c1")
        #expect(seq == 2)
        #expect(kind == .candidate)
        #expect(from == "peer-signal-id")
        #expect(payload.allCandidates.first?.ip == "10.0.0.5")
    }

    @Test("decode a connection-notify frame into a ConnectionGrant")
    func decodeConnection() throws {
        let json = """
        {"type":"connection","connection":{"id":"g1","expiresAt":"2026-07-21T10:00:00.000Z",
         "self":{"deviceId":"srv","signalId":"s-sig","role":"server"},
         "peer":{"deviceId":"cli","signalId":"c-sig","role":"client"}}}
        """
        let frame = try #require(IncomingServerFrame.decode(Data(json.utf8)))
        guard case .connection(let grant) = frame else { Issue.record("expected connection"); return }
        #expect(grant.id == "g1")
        #expect(grant.own.deviceId == "srv")
        #expect(grant.own.role == "server")
        #expect(grant.peer.deviceId == "cli")
    }

    @Test("decode an error frame")
    func decodeError() throws {
        let frame = try #require(IncomingServerFrame.decode(Data(#"{"type":"error","error":"stale_seq","connectionId":"c1"}"#.utf8)))
        guard case .error(let code, let connId) = frame else { Issue.record("expected error"); return }
        #expect(code == "stale_seq")
        #expect(connId == "c1")
    }

    @Test("unknown frame types are carried through, not fatal")
    func decodeUnknown() throws {
        let frame = try #require(IncomingServerFrame.decode(Data(#"{"type":"future-thing","x":1}"#.utf8)))
        guard case .unknown(let type) = frame else { Issue.record("expected unknown"); return }
        #expect(type == "future-thing")
    }
}

// MARK: - Device identity / enroll signing

@Suite("P2P device identity")
struct P2PDeviceIdentityTests {

    @Test("public key hex is 64 chars and the signature verifies")
    func signAndVerify() throws {
        let key = DeviceSigningKey()
        #expect(key.publicKeyHex.count == 64)
        let payload = "bromure-p2p-enroll:v1:challenge-id:some-challenge"
        let sigB64 = try #require(key.signBase64(payload))
        let sig = try #require(Data(base64Encoded: sigB64))
        // Reconstruct the public key from the hex we'd send the server and verify.
        let pubRaw = try #require(hexToData(key.publicKeyHex))
        let pub = try Curve25519.Signing.PublicKey(rawRepresentation: pubRaw)
        #expect(pub.isValidSignature(sig, for: Data(payload.utf8)))
    }

    @Test("key round-trips through its private hex")
    func roundTrip() throws {
        let key = DeviceSigningKey()
        let restored = try #require(DeviceSigningKey(privateKeyHex: key.privateKeyHex))
        #expect(restored.publicKeyHex == key.publicKeyHex)
    }

    @Test("session telemetry is organization-only — personal accounts record nothing")
    func telemetryGate() {
        func rec(_ kind: String?) -> DeviceRecord {
            DeviceRecord(privateKeyHex: "00", deviceToken: "t", deviceTokenExpiresAt: nil,
                         deviceId: "d", capability: "client", orgSlug: "s",
                         orgKind: kind, apiBase: "https://bromure.io/api")
        }
        #expect(rec("organization").recordsSessionTelemetry == true)
        #expect(rec("individual").recordsSessionTelemetry == false)
        #expect(rec(nil).recordsSessionTelemetry == false)   // unknown → privacy-safe default
    }

    @Test("enterprise identity records telemetry; a personal one does not")
    func identityTelemetry() {
        let ent = P2PIdentity(apiBase: "https://bromure.io/api", bearer: "b", installId: "i",
                              userId: "u", orgSlug: "acme", orgKind: "organization", source: .enterprise)
        #expect(ent.recordsSessionTelemetry == true)
        let indiv = P2PIdentity(apiBase: "https://bromure.io/api", bearer: "b", installId: "i",
                                userId: nil, orgSlug: "me", orgKind: "individual", source: .device)
        #expect(indiv.recordsSessionTelemetry == false)
    }

    @Test("a device record persisted before orgKind existed still decodes")
    func backwardCompatDecode() throws {
        // An older keychain record has no orgKind key — it must decode to nil,
        // not fail (and therefore record no telemetry).
        let json = """
        {"privateKeyHex":"00","deviceToken":"t","deviceId":"d",
         "capability":"client","orgSlug":"s","apiBase":"https://bromure.io/api"}
        """
        let rec = try JSONDecoder().decode(DeviceRecord.self, from: Data(json.utf8))
        #expect(rec.orgKind == nil)
        #expect(rec.recordsSessionTelemetry == false)
    }

    private func hexToData(_ hex: String) -> Data? {
        var bytes = [UInt8](); bytes.reserveCapacity(hex.count / 2)
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let b = UInt8(hex[i..<j], radix: 16) else { return nil }
            bytes.append(b); i = j
        }
        return Data(bytes)
    }
}

// MARK: - Enroll link parsing

@Suite("P2P enroll link")
struct P2PEnrollLinkTests {

    @Test("parses a bromure://enroll deep link with api override")
    func deepLink() throws {
        let link = try #require(EnrollLink(parsing: "bromure://enroll?v=1&code=abcd1234abcd1234&api=https%3A%2F%2Fbromure.io%2Fapi"))
        #expect(link.code == "abcd1234abcd1234")
        #expect(link.apiBase == "https://bromure.io/api")
    }

    @Test("a deep link without api falls back to the default control plane")
    func deepLinkNoAPI() throws {
        let link = try #require(EnrollLink(parsing: "bromure://enroll?code=abcd1234abcd1234"))
        #expect(link.apiBase == EnrollLink.defaultAPIBase)
    }

    @Test("a bare code redeems against the default")
    func bareCode() throws {
        let link = try #require(EnrollLink(parsing: "AbCd1234_-EfGh5678"))
        #expect(link.code == "AbCd1234_-EfGh5678")
        #expect(link.apiBase == EnrollLink.defaultAPIBase)
    }

    @Test("junk and non-enroll URLs are rejected")
    func rejects() {
        #expect(EnrollLink(parsing: "") == nil)
        #expect(EnrollLink(parsing: "hello world") == nil)
        #expect(EnrollLink(parsing: "https://example.com/other?x=1") == nil)
        #expect(EnrollLink(parsing: "short") == nil)
    }
}

// MARK: - Endpoint normalization

@Suite("P2P control-plane endpoint")
struct P2PEndpointTests {

    @Test("bare bromure.io gets the /api prefix; explicit paths are left alone")
    func normalize() throws {
        #expect(ControlPlaneEndpoint.normalize("https://bromure.io")?.absoluteString == "https://bromure.io/api")
        #expect(ControlPlaneEndpoint.normalize("https://bromure.io/")?.absoluteString == "https://bromure.io/api")
        #expect(ControlPlaneEndpoint.normalize("https://bromure.io/api")?.absoluteString == "https://bromure.io/api")
        // Dev bases (localhost / explicit port) are untouched.
        #expect(ControlPlaneEndpoint.normalize("http://127.0.0.1:3847")?.absoluteString == "http://127.0.0.1:3847")
    }

    @Test("device-channel URL swaps http→ws / https→wss")
    func wsURL() throws {
        let prod = try ControlPlaneEndpoint(base: "https://bromure.io/api")
        #expect(prod.deviceChannelURL.absoluteString == "wss://bromure.io/api/v1/device-channel")
        let dev = try ControlPlaneEndpoint(base: "http://127.0.0.1:3847")
        #expect(dev.deviceChannelURL.absoluteString == "ws://127.0.0.1:3847/v1/device-channel")
    }
}

// MARK: - Response decoding (exact infra JSON)

@Suite("P2P response decoding")
struct P2PResponseTests {

    @Test("GET /v1/devices row maps self→isSelf")
    func deviceRow() throws {
        let json = """
        {"id":"d1","name":"Studio Mac","capability":"server","revoked":false,
         "online":true,"lastSeenAt":"2026-07-21T10:00:00.000Z","self":true}
        """
        let d = try JSONDecoder().decode(DeviceInfo.self, from: Data(json.utf8))
        #expect(d.id == "d1")
        #expect(d.name == "Studio Mac")
        #expect(d.isServer)
        #expect(d.isSelf)
        #expect(d.online)
    }

    @Test("turn-credentials response unwraps the { turn: … } envelope")
    func turnCreds() throws {
        let json = """
        {"turn":{"urls":["stun:turn.bromure.io:3478","turn:turn.bromure.io:3478?transport=tcp"],
         "username":"1737499200:conn-1","credential":"YmFzZTY0","ttlSeconds":3600,
         "expiresAt":"2026-07-21T11:00:00.000Z","region":"default"}}
        """
        let t = try JSONDecoder().decode(TurnCredentials.self, from: Data(json.utf8))
        #expect(t.username == "1737499200:conn-1")
        #expect(t.credential == "YmFzZTY0")
        #expect(t.ttlSeconds == 3600)
        #expect(t.urls.count == 2)
        #expect(t.region == "default")
    }

    @Test("TURN url host/port/transport parsing")
    func turnURLParse() {
        let a = TurnRelayTransport.parseHostPort(fromURL: "turn:turn.bromure.io:3478?transport=tcp")
        #expect(a?.host == "turn.bromure.io")
        #expect(a?.port == 3478)
        #expect(a?.transport == "tcp")
        let b = TurnRelayTransport.parseHostPort(fromURL: "stun:turn.bromure.io")
        #expect(b?.host == "turn.bromure.io")
        #expect(b?.port == 3478)
        #expect(b?.transport == nil)
    }

    @Test("connection report encodes connected without failureStage")
    func reportConnected() throws {
        let r = ConnectionReport.connected(pathKind: .direct, timeToConnectedMs: 843)
        let obj = try #require((try JSONSerialization.jsonObject(with: JSONEncoder().encode(r))) as? [String: Any])
        #expect(obj["outcome"] as? String == "connected")
        #expect(obj["pathKind"] as? String == "direct")
        #expect(obj["timeToConnectedMs"] as? Int == 843)
        #expect(obj["failureStage"] == nil)
    }

    @Test("connection report clamps time-to-connected into the server's 0…600000 range")
    func reportClamp() throws {
        let r = ConnectionReport.connected(pathKind: .relay, timeToConnectedMs: 10_000_000)
        #expect(r.timeToConnectedMs == 600_000)
    }

    @Test("connection report encodes failed without path fields")
    func reportFailed() throws {
        let r = ConnectionReport.failed(stage: .ice)
        let obj = try #require((try JSONSerialization.jsonObject(with: JSONEncoder().encode(r))) as? [String: Any])
        #expect(obj["outcome"] as? String == "failed")
        #expect(obj["failureStage"] as? String == "ice")
        #expect(obj["pathKind"] == nil)
        #expect(obj["timeToConnectedMs"] == nil)
    }
}
