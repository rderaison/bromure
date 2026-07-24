import Crypto
import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - STUN message codec (RFC 5389, TURN attributes from RFC 5766/6062)

/// The minimal STUN wire codec the TURN-TCP relay path needs: Binding (learn
/// our public address), Allocate/Refresh/CreatePermission (RFC 5766) and
/// ConnectionBind/ConnectionAttempt (RFC 6062), with long-term-credential
/// MESSAGE-INTEGRITY (the TURN REST API creds minted by
/// `POST /v1/connections/:id/turn-credentials`).
///
/// Deliberately not a general STUN stack: no ICE, no FINGERPRINT emission, no
/// response-integrity verification — the relay is untrusted by design
/// (REMOTE_P2P_PLAN.md security invariant: SSH end-to-end is the boundary; a
/// hostile relay can only deny service, never read or impersonate).
struct STUNMessage {
    // Message types (method | class, RFC 5389 §6 bit-interleave, precomputed).
    static let bindingRequest: UInt16        = 0x0001
    static let bindingSuccess: UInt16        = 0x0101
    static let allocateRequest: UInt16       = 0x0003
    static let allocateSuccess: UInt16       = 0x0103
    static let allocateError: UInt16         = 0x0113
    static let refreshRequest: UInt16        = 0x0004
    static let refreshSuccess: UInt16        = 0x0104
    static let createPermissionRequest: UInt16 = 0x0008
    static let createPermissionSuccess: UInt16 = 0x0108
    static let connectionBindRequest: UInt16 = 0x000B
    static let connectionBindSuccess: UInt16 = 0x010B
    /// RFC 6062 §4.4 — server → client indication that a peer TCP-connected to
    /// the relayed address; carries CONNECTION-ID + XOR-PEER-ADDRESS.
    static let connectionAttemptIndication: UInt16 = 0x001C
    // RFC 5766 UDP relay verbs (the resilience path — see RelayARQ.swift).
    static let channelBindRequest: UInt16    = 0x0009
    static let channelBindSuccess: UInt16    = 0x0109
    /// Client → server: relay `DATA` to `XOR-PEER-ADDRESS` (pre-channel).
    static let sendIndication: UInt16        = 0x0016
    /// Server → client: a peer sent us `DATA` from `XOR-PEER-ADDRESS`.
    static let dataIndication: UInt16        = 0x0017

    // Attributes.
    static let attrUsername: UInt16          = 0x0006
    static let attrMessageIntegrity: UInt16  = 0x0008
    static let attrErrorCode: UInt16         = 0x0009
    static let attrLifetime: UInt16          = 0x000D
    static let attrChannelNumber: UInt16     = 0x000C
    static let attrXorPeerAddress: UInt16    = 0x0012
    static let attrData: UInt16              = 0x0013
    static let attrRealm: UInt16             = 0x0014
    static let attrNonce: UInt16             = 0x0015
    static let attrXorRelayedAddress: UInt16 = 0x0016
    static let attrRequestedTransport: UInt16 = 0x0019
    static let attrXorMappedAddress: UInt16  = 0x0020
    static let attrConnectionID: UInt16      = 0x002A

    static let magic: UInt32 = 0x2112_A442
    /// REQUESTED-TRANSPORT protocol numbers.
    static let protoTCP: UInt8 = 6
    static let protoUDP: UInt8 = 17

    var type: UInt16
    /// 96-bit transaction id, matching a response to its request.
    var txid: [UInt8]
    var attrs: [(type: UInt16, value: [UInt8])] = []

    init(type: UInt16, txid: [UInt8] = STUNMessage.newTxid()) {
        self.type = type
        self.txid = txid
    }

    static func newTxid() -> [UInt8] {
        var g = SystemRandomNumberGenerator()
        return (0..<12).map { _ in UInt8.random(in: .min ... .max, using: &g) }
    }

    var isSuccess: Bool { (type & 0x0110) == 0x0100 }
    var isError: Bool { (type & 0x0110) == 0x0110 }
    var isIndication: Bool { (type & 0x0110) == 0x0010 }

    // MARK: Building

    mutating func add(_ type: UInt16, _ value: [UInt8]) {
        attrs.append((type, value))
    }

    mutating func add(_ type: UInt16, string: String) {
        add(type, [UInt8](string.utf8))
    }

    mutating func add(_ type: UInt16, u32: UInt32) {
        add(type, [UInt8(truncatingIfNeeded: u32 >> 24), UInt8(truncatingIfNeeded: u32 >> 16),
                   UInt8(truncatingIfNeeded: u32 >> 8), UInt8(truncatingIfNeeded: u32)])
    }

    /// XOR-*-ADDRESS (RFC 5389 §15.2): port ^ magic>>16; v4 addr ^ magic,
    /// v6 addr ^ (magic || txid). Returns false for an unparseable IP.
    @discardableResult
    mutating func addXorAddress(_ type: UInt16, ip: String, port: Int) -> Bool {
        var value: [UInt8]
        let xport = UInt16(truncatingIfNeeded: port) ^ UInt16(truncatingIfNeeded: STUNMessage.magic >> 16)
        var v4 = in_addr()
        var v6 = in6_addr()
        if inet_pton(AF_INET, ip, &v4) == 1 {
            value = [0, 0x01, UInt8(truncatingIfNeeded: xport >> 8), UInt8(truncatingIfNeeded: xport)]
            let raw = withUnsafeBytes(of: &v4) { [UInt8]($0) }   // network order
            let key = STUNMessage.magicBytes
            value += (0..<4).map { raw[$0] ^ key[$0] }
        } else if inet_pton(AF_INET6, ip, &v6) == 1 {
            value = [0, 0x02, UInt8(truncatingIfNeeded: xport >> 8), UInt8(truncatingIfNeeded: xport)]
            let raw = withUnsafeBytes(of: &v6) { [UInt8]($0) }
            let key = STUNMessage.magicBytes + txid
            value += (0..<16).map { raw[$0] ^ key[$0] }
        } else {
            return false
        }
        add(type, value)
        return true
    }

    private static var magicBytes: [UInt8] {
        [UInt8(truncatingIfNeeded: magic >> 24), UInt8(truncatingIfNeeded: magic >> 16),
         UInt8(truncatingIfNeeded: magic >> 8), UInt8(truncatingIfNeeded: magic)]
    }

    /// Serialize header + attributes (each padded to a 4-byte boundary; the
    /// length field counts the unpadded value, RFC 5389 §15).
    func encoded() -> [UInt8] {
        var body: [UInt8] = []
        for (t, v) in attrs {
            body += [UInt8(truncatingIfNeeded: t >> 8), UInt8(truncatingIfNeeded: t),
                     UInt8(truncatingIfNeeded: v.count >> 8), UInt8(truncatingIfNeeded: v.count)]
            body += v
            while body.count % 4 != 0 { body.append(0) }
        }
        var out: [UInt8] = [UInt8(truncatingIfNeeded: type >> 8), UInt8(truncatingIfNeeded: type),
                            UInt8(truncatingIfNeeded: body.count >> 8), UInt8(truncatingIfNeeded: body.count)]
        out += STUNMessage.magicBytes
        out += txid
        out += body
        return out
    }

    // MARK: Long-term-credential integrity (RFC 5389 §15.4)

    /// key = MD5(username ":" realm ":" password). SASLprep is skipped — the
    /// REST-API username (`<unix-expiry>:<connectionId>`) and realm
    /// (`bromure.io`) are plain ASCII by construction.
    static func longTermKey(username: String, realm: String, password: String) -> [UInt8] {
        [UInt8](Insecure.MD5.hash(data: Data("\(username):\(realm):\(password)".utf8)))
    }

    /// Append MESSAGE-INTEGRITY: HMAC-SHA1 over the message up to (excluding)
    /// the attribute itself, with the header's length field already counting
    /// the 24-byte attribute — the RFC's one wire-format subtlety.
    mutating func sign(key: [UInt8]) {
        var bytes = encoded()
        let withMI = bytes.count - 20 + 24
        bytes[2] = UInt8(truncatingIfNeeded: withMI >> 8)
        bytes[3] = UInt8(truncatingIfNeeded: withMI)
        let mac = HMAC<Insecure.SHA1>.authenticationCode(for: Data(bytes), using: SymmetricKey(data: Data(key)))
        add(STUNMessage.attrMessageIntegrity, [UInt8](mac))
    }

    // MARK: Parsing

    /// Decode one complete message (caller has already framed it off the TCP
    /// stream via the header length). nil on bad magic/framing.
    static func decode(_ bytes: [UInt8]) -> STUNMessage? {
        guard bytes.count >= 20 else { return nil }
        let type = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
        guard type & 0xC000 == 0 else { return nil }
        let length = Int(bytes[2]) << 8 | Int(bytes[3])
        let cookie = UInt32(bytes[4]) << 24 | UInt32(bytes[5]) << 16 | UInt32(bytes[6]) << 8 | UInt32(bytes[7])
        guard cookie == magic, bytes.count >= 20 + length else { return nil }
        var msg = STUNMessage(type: type, txid: Array(bytes[8..<20]))
        var off = 20
        let end = 20 + length
        while off + 4 <= end {
            let t = UInt16(bytes[off]) << 8 | UInt16(bytes[off + 1])
            let l = Int(bytes[off + 2]) << 8 | Int(bytes[off + 3])
            guard off + 4 + l <= end else { break }
            msg.attrs.append((t, Array(bytes[(off + 4)..<(off + 4 + l)])))
            off += 4 + l
            while off % 4 != 0 { off += 1 }   // skip padding
        }
        return msg
    }

    func attr(_ type: UInt16) -> [UInt8]? {
        attrs.first { $0.type == type }?.value
    }

    func string(_ type: UInt16) -> String? {
        attr(type).map { String(decoding: $0, as: UTF8.self) }
    }

    func u32(_ type: UInt16) -> UInt32? {
        guard let v = attr(type), v.count >= 4 else { return nil }
        return UInt32(v[0]) << 24 | UInt32(v[1]) << 16 | UInt32(v[2]) << 8 | UInt32(v[3])
    }

    /// ERROR-CODE → the numeric code (class × 100 + number), e.g. 401, 438.
    var errorCode: Int? {
        guard let v = attr(STUNMessage.attrErrorCode), v.count >= 4 else { return nil }
        return Int(v[2] & 0x07) * 100 + Int(v[3])
    }

    /// Add a CHANNEL-NUMBER attribute (channel + 2 bytes RFFU).
    mutating func add(channelNumber: UInt16) {
        add(STUNMessage.attrChannelNumber,
            [UInt8(truncatingIfNeeded: channelNumber >> 8), UInt8(truncatingIfNeeded: channelNumber), 0, 0])
    }

    /// Un-XOR an XOR-*-ADDRESS attribute back to (ip, port).
    func xorAddress(_ type: UInt16) -> (ip: String, port: Int)? {
        guard let v = attr(type), v.count >= 8 else { return nil }
        let key: [UInt8] = [UInt8(truncatingIfNeeded: STUNMessage.magic >> 24),
                            UInt8(truncatingIfNeeded: STUNMessage.magic >> 16),
                            UInt8(truncatingIfNeeded: STUNMessage.magic >> 8),
                            UInt8(truncatingIfNeeded: STUNMessage.magic)] + txid
        let port = Int((UInt16(v[2]) << 8 | UInt16(v[3])) ^ UInt16(truncatingIfNeeded: STUNMessage.magic >> 16))
        switch v[1] {
        case 0x01:
            guard v.count >= 8 else { return nil }
            let a = (0..<4).map { v[4 + $0] ^ key[$0] }
            return ("\(a[0]).\(a[1]).\(a[2]).\(a[3])", port)
        case 0x02:
            guard v.count >= 20 else { return nil }
            let a = (0..<16).map { v[4 + $0] ^ key[$0] }
            var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            var addr = in6_addr()
            withUnsafeMutableBytes(of: &addr) { $0.copyBytes(from: a) }
            guard inet_ntop(AF_INET6, &addr, &buf, socklen_t(buf.count)) != nil else { return nil }
            return (String(cString: buf), port)
        default:
            return nil
        }
    }
}

// MARK: - ChannelData (RFC 5766 §11.4) — the low-overhead UDP relay data framing

/// Once a channel is bound (`ChannelBind`), the relay wraps peer↔client data in
/// a 4-byte ChannelData header instead of a ~36-byte Send/Data STUN indication —
/// the difference matters on a slow link carrying many small SSH segments:
///
///     0                   1                   2                   3
///     +-------+-------+-------+-------+-------------------------------+
///     |     channel (2)       |     length (2)        | data ...      |
///     +-------+-------+-------+-------+-------------------------------+
///
/// Channel numbers live in 0x4000–0x7FFF, which is how a received datagram is
/// told apart from a STUN message (whose first two bits are always 0) without
/// ambiguity. On UDP the final message needs no 4-byte padding (RFC 5766
/// §11.5), so we emit none and tolerate its absence on receive.
enum ChannelData {
    static let minChannel: UInt16 = 0x4000
    static let maxChannel: UInt16 = 0x7FFE   // 0x7FFF is reserved

    /// A datagram is ChannelData (not STUN) iff its first two bits are `01`.
    static func isChannelData(_ firstByte: UInt8) -> Bool { (firstByte & 0xC0) == 0x40 }

    static func encode(channel: UInt16, _ payload: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [UInt8(truncatingIfNeeded: channel >> 8), UInt8(truncatingIfNeeded: channel),
                            UInt8(truncatingIfNeeded: payload.count >> 8), UInt8(truncatingIfNeeded: payload.count)]
        out += payload
        return out
    }

    /// Parse a received ChannelData frame → (channel, payload). Returns nil if it
    /// isn't a channel frame, the channel is out of range, or it's truncated.
    static func decode(_ bytes: [UInt8]) -> (channel: UInt16, payload: [UInt8])? {
        guard bytes.count >= 4, isChannelData(bytes[0]) else { return nil }
        let channel = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
        guard channel >= minChannel, channel <= maxChannel else { return nil }
        let len = Int(bytes[2]) << 8 | Int(bytes[3])
        guard bytes.count >= 4 + len else { return nil }
        return (channel, Array(bytes[4 ..< 4 + len]))
    }
}
