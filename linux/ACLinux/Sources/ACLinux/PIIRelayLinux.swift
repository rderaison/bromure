import Foundation

/// A reply PII protection restores, on the Linux relay (macOS: relayUpstream
/// with its responseRestorer, over URLSession's decoded body): the upstream's
/// body is read through its framing (a Content-Length, chunks, or up to the
/// close), its stand-ins put back by the shared PIIResponseRestorer, and sent
/// on re-chunked (the restored body's length differs), as macOS sends it; to
/// an HTTP/1.0 guest, up to the close instead.
///
/// A reply with no body (204, 304) goes on as it came; so does one still
/// content- or transfer-coded (identity was asked for; nothing here decodes
/// it), recorded: its stand-ins stay in it, which leaks nothing. A reply
/// whose length can't be trusted (negative, not a number, two different
/// ones) is refused, and broken chunk framing ends the relay: fail closed.
// @port-skip linux-only: relayUpstream's restorer framing, on the Linux relay's raw wire
final class PIIRelay {
    enum Head {
        /// The head as it goes to the guest; the body is restored.
        case restored(Data)
        /// The reply goes on as it came, unrestored.
        case asItCame
        /// The reply can't be framed with certainty: refused.
        case refused(String)
    }

    private enum Body {
        case length(Int)
        case chunked(ChunkState)
        case untilClose
    }

    private enum ChunkState {
        case size(Data)
        case data(Int)
        case dataEnd(Int)
        /// Trailer bytes read so far, and the last four (the end is CRLF CRLF,
        /// or a bare CRLF with no trailer).
        case trailers(count: Int, last: [UInt8])
    }

    static let maxSizeLine = 4096
    static let maxTrailers = 64 << 10

    private let vault: PIIVault
    private let chunkedOut: Bool
    private let host: String
    private let profileID: UUID
    private var restorer: PIIResponseRestorer?
    private var body = Body.untilClose
    /// The body is complete (by its framing) and its end has gone out.
    private(set) var ended = false
    /// The upstream's framing broke mid-body: the guest's reply is cut, never
    /// ended cleanly.
    private(set) var failed = false

    /// Whether the body is being restored (a head that has one, readable).
    // @port-skip linux-only: see PIIRelay
    var restoring: Bool { restorer != nil }

    /// `chunkedOut`: the guest speaks HTTP/1.1 (an HTTP/1.0 guest gets the
    /// restored body up to the close).
    // @port-skip linux-only: see PIIRelay
    init(vault: PIIVault, chunkedOut: Bool = true, host: String = "", profileID: UUID = UUID()) {
        self.vault = vault
        self.chunkedOut = chunkedOut
        self.host = host
        self.profileID = profileID
    }

    /// The final response's head (through its blank line).
    // @port-skip linux-only: see PIIRelay
    func head(_ head: Data) -> Head {
        guard let text = String(data: head, encoding: .isoLatin1) else { return .refused("an unreadable head") }
        let lines = text.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        let status = lines.first.flatMap { Int($0.split(separator: " ").dropFirst().first ?? "") } ?? 0
        var lengths: [String] = [], transfer: [String] = [], coding: [String] = []
        var contentType = ""
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            let tokens = value.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            switch name {
            case "content-length": lengths += tokens
            case "transfer-encoding": transfer += tokens
            case "content-encoding": coding += tokens.filter { $0 != "identity" && !$0.isEmpty }
            case "content-type": contentType = value
            default: break
            }
        }
        guard status >= 200, status != 204, status != 304 else { return .asItCame }
        if !transfer.isEmpty {
            // Chunked, and only chunked: any other transfer coding isn't read here.
            guard transfer == ["chunked"] else { return notRestored("transfer-coded (\(transfer.joined(separator: ", ")))") }
            body = .chunked(.size(Data()))
        } else if !lengths.isEmpty {
            guard lengths.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { $0 >= 0x30 && $0 <= 0x39 } }),
                  Set(lengths).count == 1, let n = Int(lengths[0]) else {
                return .refused("a Content-Length that can't be trusted (\(lengths.joined(separator: ", ")))")
            }
            body = .length(n)
        } else {
            body = .untilClose
        }
        guard coding.isEmpty else { return notRestored("content-coded (\(coding.joined(separator: ", ")))") }
        restorer = PIIResponseRestorer(vault: vault, contentType: contentType)
        let kept = lines.filter { line in
            let name = line.split(separator: ":", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces).lowercased()
            return name != "content-length" && name != "transfer-encoding"
        }
        let out = kept.joined(separator: "\r\n") + (chunkedOut ? "\r\nTransfer-Encoding: chunked" : "") + "\r\n\r\n"
        var data = out.data(using: .isoLatin1) ?? Data(out.utf8)
        if case .length(0) = body { data += end() }
        return .restored(data)
    }

    // @port-skip linux-only: see PIIRelay
    private func notRestored(_ why: String) -> Head {
        ProxyPolicy.recordScanSkipped(host: host, path: "", engines: ["pii"],
                                      reason: "reply \(why) though identity was asked for: its stand-ins were not restored",
                                      profileID: profileID)
        return .asItCame
    }

    /// Body bytes from the upstream; what goes to the guest (and the body's
    /// end once its framing says it's complete).
    // @port-skip linux-only: see PIIRelay
    func feed(_ bytes: Data) -> Data {
        guard let restorer, !ended, !failed else { return Data() }
        var plain = Data()
        var i = bytes.startIndex
        var complete = false
        func fail() -> Data { failed = true; return frame(restorer.feed(plain)) }
        while i < bytes.endIndex, !complete {
            switch body {
            case .untilClose:
                plain.append(bytes[i...])
                i = bytes.endIndex
            case .length(let left):
                let n = min(left, bytes.endIndex - i)
                plain.append(bytes[i..<(i + n)])
                i += n
                body = .length(left - n)
                complete = left - n == 0
            case .chunked(let state):
                switch state {
                case .size(var line):
                    line.append(bytes[i]); i += 1
                    guard line.count >= 2, line.suffix(2) == Data("\r\n".utf8) else {
                        if line.count > Self.maxSizeLine { return fail() }
                        body = .chunked(.size(line)); continue
                    }
                    let hex = String(decoding: line.dropLast(2), as: UTF8.self)
                        .split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                    guard !hex.isEmpty, hex.allSatisfy(\.isHexDigit), let n = Int(hex, radix: 16) else { return fail() }
                    body = .chunked(n == 0 ? .trailers(count: 0, last: []) : .data(n))
                case .data(let left):
                    let n = min(left, bytes.endIndex - i)
                    plain.append(bytes[i..<(i + n)])
                    i += n
                    body = .chunked(left - n == 0 ? .dataEnd(2) : .data(left - n))
                case .dataEnd(let left):
                    // The CRLF after a chunk's data.
                    guard bytes[i] == (left == 2 ? 0x0D : 0x0A) else { return fail() }
                    i += 1
                    body = .chunked(left == 1 ? .size(Data()) : .dataEnd(left - 1))
                case .trailers(let count, var last):
                    last.append(bytes[i]); i += 1
                    if last.count > 4 { last.removeFirst() }
                    let c = count + 1
                    if (c == 2 && last == [0x0D, 0x0A]) || (c >= 4 && last == [0x0D, 0x0A, 0x0D, 0x0A]) {
                        complete = true
                    } else if c > Self.maxTrailers {
                        return fail()
                    } else {
                        body = .chunked(.trailers(count: c, last: last))
                    }
                }
            }
        }
        var out = frame(restorer.feed(plain))
        if complete { out.append(end()) }
        return out
    }

    /// The upstream closed. A body read up to the close ends here (what's
    /// held, then the last chunk); one cut short of its length or its last
    /// chunk gets what's held but no end, so the guest sees it cut.
    // @port-skip linux-only: see PIIRelay
    func finish() -> Data {
        guard let restorer, !ended, !failed else { return Data() }
        if case .untilClose = body { return end() }
        failed = true
        return frame(restorer.finish())
    }

    // @port-skip linux-only: see PIIRelay
    private func end() -> Data {
        guard let restorer else { return Data() }
        ended = true
        return frame(restorer.finish()) + (chunkedOut ? Data("0\r\n\r\n".utf8) : Data())
    }

    // @port-skip linux-only: see PIIRelay
    private func frame(_ d: Data) -> Data {
        guard !d.isEmpty else { return Data() }
        guard chunkedOut else { return d }
        return Data(String(d.count, radix: 16).utf8) + Data("\r\n".utf8) + d + Data("\r\n".utf8)
    }
}
