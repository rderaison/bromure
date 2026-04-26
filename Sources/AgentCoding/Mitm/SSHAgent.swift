import Foundation
import Crypto

/// In-memory SSH-agent that speaks the standard ssh-agent wire
/// protocol (draft-miller-ssh-agent-04). One per host process; serves
/// every profile via vsock — the per-profile selection happens via the
/// VZVirtioSocketListener delegate that captures the profileID.
///
/// **Threat model**: the private keys live only in `~/Library/Application
/// Support/BromureAC/profiles/<id>/ssh/id_ed25519` on the host. The VM
/// has `SSH_AUTH_SOCK` pointing at a unix socket that's bridged to vsock
/// here. The VM can ask for `IDENTITIES_ANSWER` and `SIGN_RESPONSE` but
/// cannot ever read or extract the key bytes — the agent protocol has
/// no "give me the private key" message.
public final class SSHAgentServer: @unchecked Sendable {
    private var keysByProfile: [UUID: [AgentKey]] = [:]
    private let lock = NSLock()

    public init() {}

    /// Replace the key set for a profile. Called when the session
    /// launches with whatever ed25519 keys live under the profile's
    /// host-side ssh dir.
    public func setKeys(_ keys: [AgentKey], for profileID: UUID) {
        lock.lock(); defer { lock.unlock() }
        keysByProfile[profileID] = keys
    }

    public func clearKeys(for profileID: UUID) {
        lock.lock(); defer { lock.unlock() }
        keysByProfile.removeValue(forKey: profileID)
    }

    private func keys(for profileID: UUID) -> [AgentKey] {
        lock.lock(); defer { lock.unlock() }
        return keysByProfile[profileID] ?? []
    }

    /// Serve one client connection. Returns when the client closes,
    /// or on protocol error.
    public func serve(fd: Int32, profileID: UUID) {
        defer { close(fd) }
        do {
            try loop(fd: fd, profileID: profileID)
        } catch {
            FileHandle.standardError.write(Data(
                "[ssh-agent] connection ended: \(error)\n".utf8))
        }
    }

    private func loop(fd: Int32, profileID: UUID) throws {
        while true {
            // 4-byte big-endian length, then payload.
            guard let lenBuf = try readExact(fd: fd, count: 4) else { return }
            let length = Int(UInt32(bigEndian: lenBuf.withUnsafeBytes { $0.load(as: UInt32.self) }))
            if length == 0 || length > (256 * 1024) {
                throw SSHError.protocolError("invalid frame length \(length)")
            }
            guard let payload = try readExact(fd: fd, count: length), payload.count == length else {
                throw SSHError.protocolError("short read")
            }
            let msgType = payload[0]
            let body = payload.subdata(in: 1..<payload.count)

            switch msgType {
            case AgentMsg.requestIdentities.rawValue:
                let resp = try handleRequestIdentities(profileID: profileID)
                try writeFrame(fd: fd, payload: resp)
            case AgentMsg.signRequest.rawValue:
                let resp = try handleSignRequest(body: body, profileID: profileID)
                try writeFrame(fd: fd, payload: resp)
            default:
                // SSH_AGENT_FAILURE for anything we don't understand.
                try writeFrame(fd: fd, payload: Data([AgentMsg.failure.rawValue]))
            }
        }
    }

    // MARK: - Message handlers

    private func handleRequestIdentities(profileID: UUID) throws -> Data {
        let profileKeys = self.keys(for: profileID)
        // Multiplex two agents into one identities answer:
        //   • Bromure's private ssh-agent (always present; holds the
        //     per-profile keys we ssh-add'd at session launch)
        //   • The user's macOS launchd ssh-agent (optional; their
        //     personal keys)
        // De-dupe by public-key blob so a key the user added to both
        // agents only shows up once in the VM.
        var seen = Set<Data>()
        var entries: [(blob: Data, comment: String)] = []

        for key in profileKeys where !seen.contains(key.publicKeyBlob) {
            seen.insert(key.publicKeyBlob)
            entries.append((key.publicKeyBlob, key.comment))
        }
        for ident in fetchIdentities(from: HostAgentClient._bromurePrivate)
            where !seen.contains(ident.blob)
        {
            seen.insert(ident.blob)
            entries.append(ident)
        }
        for ident in fetchIdentities(from: HostAgentClient.macOSUser)
            where !seen.contains(ident.blob)
        {
            seen.insert(ident.blob)
            entries.append(ident)
        }

        var out = Data()
        out.append(AgentMsg.identitiesAnswer.rawValue)
        out.append(uint32(UInt32(entries.count)))
        for entry in entries {
            out.append(string(entry.blob))
            out.append(string(Data(entry.comment.utf8)))
        }
        return out
    }

    private func handleSignRequest(body: Data, profileID: UUID) throws -> Data {
        var cursor = 0
        let keyBlob = try takeString(body: body, cursor: &cursor)
        let data    = try takeString(body: body, cursor: &cursor)
        // RSA keys carry SHA-2 algorithm hints in this u32 (bit 1 ==
        // rsa-sha2-256, bit 2 == rsa-sha2-512). Modern OpenSSH servers
        // reject the legacy SHA-1 ssh-rsa signatures, so we must forward
        // the flags verbatim — dropping them makes the host agent sign
        // with SHA-1 and the client throws "incorrect signature type".
        let flags = (try? takeUInt32(body: body, cursor: &cursor)) ?? 0

        // First match: in-process per-profile key. We hold the seed,
        // so we can sign locally with no socket round-trip.
        let keys = self.keys(for: profileID)
        if let match = keys.first(where: { $0.publicKeyBlob == keyBlob }) {
            let signature = try match.sign(data)
            var sshSig = Data()
            sshSig.append(string(Data("ssh-ed25519".utf8)))
            sshSig.append(string(signature))
            var out = Data()
            out.append(AgentMsg.signResponse.rawValue)
            out.append(string(sshSig))
            return out
        }

        // Forward to whichever agent advertises the key. Try our
        // private agent first (cheaper, always available); fall
        // through to the macOS user agent.
        var fwd = Data()
        fwd.append(AgentMsg.signRequest.rawValue)
        fwd.append(string(keyBlob))
        fwd.append(string(data))
        fwd.append(uint32(flags))
        for client in [HostAgentClient._bromurePrivate, HostAgentClient.macOSUser] {
            guard let c = client else { continue }
            if let resp = c.request(fwd), !resp.isEmpty,
               resp[0] == AgentMsg.signResponse.rawValue {
                return resp
            }
        }
        return Data([AgentMsg.failure.rawValue])
    }

    /// Query a single agent for its identities. Returns empty on
    /// nil-client / I/O failure / protocol mismatch.
    private func fetchIdentities(from client: HostAgentClient?)
        -> [(blob: Data, comment: String)]
    {
        guard let client else { return [] }
        let req = Data([AgentMsg.requestIdentities.rawValue])
        guard let resp = client.request(req), !resp.isEmpty,
              resp[0] == AgentMsg.identitiesAnswer.rawValue else {
            return []
        }
        var cursor = 1
        guard let count = try? takeUInt32(body: resp, cursor: &cursor) else { return [] }
        var result: [(Data, String)] = []
        for _ in 0..<Int(count) {
            guard let blob = try? takeString(body: resp, cursor: &cursor),
                  let commentBytes = try? takeString(body: resp, cursor: &cursor) else {
                return result
            }
            result.append((blob, String(data: commentBytes, encoding: .utf8) ?? ""))
        }
        return result
    }
}

// MARK: - Wire helpers

private enum AgentMsg: UInt8 {
    case failure          = 5
    case success          = 6
    case requestIdentities = 11
    case identitiesAnswer  = 12
    case signRequest       = 13
    case signResponse      = 14
}

private func uint32(_ v: UInt32) -> Data {
    var be = v.bigEndian
    return Data(bytes: &be, count: 4)
}

private func string(_ payload: Data) -> Data {
    var out = uint32(UInt32(payload.count))
    out.append(payload)
    return out
}

private func takeUInt32(body: Data, cursor: inout Int) throws -> UInt32 {
    guard cursor + 4 <= body.count else { throw SSHError.protocolError("u32 OOB") }
    let v = body.subdata(in: cursor..<(cursor + 4))
        .withUnsafeBytes { $0.load(as: UInt32.self) }
    cursor += 4
    return UInt32(bigEndian: v)
}

private func takeString(body: Data, cursor: inout Int) throws -> Data {
    let n = try takeUInt32(body: body, cursor: &cursor)
    let len = Int(n)
    guard cursor + len <= body.count else { throw SSHError.protocolError("string OOB") }
    let s = body.subdata(in: cursor..<(cursor + len))
    cursor += len
    return s
}

private func readExact(fd: Int32, count: Int) throws -> Data? {
    var buf = [UInt8](repeating: 0, count: count)
    var got = 0
    while got < count {
        let n = buf.withUnsafeMutableBufferPointer { ptr -> Int in
            read(fd, ptr.baseAddress!.advanced(by: got), count - got)
        }
        if n == 0 { return got == 0 ? nil : Data(buf.prefix(got)) }
        if n < 0 {
            if errno == EINTR { continue }
            throw SSHError.protocolError("read errno \(errno)")
        }
        got += n
    }
    return Data(buf)
}

private func writeFrame(fd: Int32, payload: Data) throws {
    var frame = uint32(UInt32(payload.count))
    frame.append(payload)
    try frame.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        var sent = 0
        while sent < frame.count {
            let n = write(fd, raw.baseAddress!.advanced(by: sent), frame.count - sent)
            if n < 0 {
                if errno == EINTR { continue }
                throw SSHError.protocolError("write errno \(errno)")
            }
            sent += n
        }
    }
}

// MARK: - Key model

/// One ed25519 keypair available to a profile via the agent.
public struct AgentKey: Sendable {
    public let comment: String
    /// Raw 32-byte ed25519 public key.
    public let publicKey: Data
    /// Raw 32-byte ed25519 seed. In-process visibility is fine — the
    /// security model is "never crosses vsock", not "never visible to
    /// any Swift code".
    public let seed: Data

    public init(comment: String, publicKey: Data, seed: Data) {
        self.comment = comment
        self.publicKey = publicKey
        self.seed = seed
    }

    /// SSH-protocol-formatted public key blob, the wire format the
    /// agent advertises and that ssh clients hand back in sign requests:
    ///   string("ssh-ed25519") + string(raw32-byte-public-key)
    public var publicKeyBlob: Data {
        var out = Data()
        out.append(string(Data("ssh-ed25519".utf8)))
        out.append(string(publicKey))
        return out
    }

    func sign(_ data: Data) throws -> Data {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        return Data(try key.signature(for: data))
    }
}

// MARK: - Errors

public enum SSHError: Error, CustomStringConvertible {
    case protocolError(String)
    case keyParseError(String)
    public var description: String {
        switch self {
        case .protocolError(let s):  return "ssh-agent protocol: \(s)"
        case .keyParseError(let s):  return "ssh-agent key parse: \(s)"
        }
    }
}
