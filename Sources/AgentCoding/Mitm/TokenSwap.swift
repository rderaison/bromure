import Foundation

/// Per-profile fake→real token map. Built each time a session is
/// launched from the profile's saved tools + git creds + (later)
/// manual entries. Lives only in memory on the host — the VM never
/// sees the real values.
public struct TokenMap: Sendable {
    public struct Entry: Sendable {
        public let fake: String
        public let real: String
        /// Optional host pattern (substring match). Empty/nil = swap on
        /// any host. Used when the same fake token might appear in
        /// requests where we want it left alone for some hosts.
        public let host: String?
        /// Header to swap in. Default `Authorization` (Bearer prefix).
        public let header: Header

        public enum Header: String, Sendable {
            case authorization     // Authorization: Bearer <token>
            case xApiKey           // x-api-key: <token>
            case anthropicApiKey   // x-api-key: <token> (Anthropic uses this)
            case openaiApiKey      // Authorization: Bearer <token> (OpenAI)
        }

        public init(fake: String, real: String, host: String? = nil, header: Header = .authorization) {
            self.fake = fake
            self.real = real
            self.host = host
            self.header = header
        }
    }

    public var entries: [Entry]

    public init(entries: [Entry] = []) {
        self.entries = entries
    }

    public var isEmpty: Bool { entries.isEmpty }
}

/// HTTP request inspector + token swapper. Operates on a request as
/// raw bytes (header section + body) to keep things zero-copy and
/// preserve byte-for-byte semantics of unrelated headers.
public final class TokenSwapper: @unchecked Sendable {
    private var maps: [UUID: TokenMap] = [:]
    private let lock = NSLock()

    public init() {}

    /// Replace the token map for a profile. Called by the host each
    /// time a session launches (and on profile edit while running, if
    /// we ever wire that).
    public func setMap(_ map: TokenMap, for profileID: UUID) {
        lock.lock(); defer { lock.unlock() }
        maps[profileID] = map
    }

    public func clearMap(for profileID: UUID) {
        lock.lock(); defer { lock.unlock() }
        maps.removeValue(forKey: profileID)
    }

    /// Returns the (modified bytes, swap report) for the given raw
    /// request. If no swap applied, the original buffer is returned
    /// untouched.
    public func swap(rawRequest: Data, host: String, profileID: UUID) -> SwapResult {
        lock.lock()
        let map = maps[profileID]
        lock.unlock()
        guard let map, !map.isEmpty else { return SwapResult(modified: rawRequest, swaps: []) }

        // Find header section end. HTTP delimits headers from body
        // with CRLFCRLF. Anything past that is the body — never touch.
        guard let headerEndIdx = rawRequest.range(of: Data("\r\n\r\n".utf8))?.lowerBound else {
            return SwapResult(modified: rawRequest, swaps: [])
        }

        var headerBytes = rawRequest.subdata(in: 0..<headerEndIdx)
        let bodyBytes   = rawRequest.subdata(in: headerEndIdx..<rawRequest.count)

        guard var headerStr = String(data: headerBytes, encoding: .ascii) else {
            return SwapResult(modified: rawRequest, swaps: [])
        }

        var swaps: [SwapRecord] = []
        for entry in map.entries {
            if let h = entry.host, !host.contains(h) { continue }
            // Sweep all token positions — the same fake might appear in
            // multiple headers (rare but possible).
            while let r = headerStr.range(of: entry.fake) {
                headerStr.replaceSubrange(r, with: entry.real)
                swaps.append(SwapRecord(
                    fakePreview: Self.preview(entry.fake),
                    realPreview: Self.preview(entry.real),
                    host: host
                ))
            }
        }

        // No-op if no swap actually fired — return the original buffer.
        if swaps.isEmpty {
            return SwapResult(modified: rawRequest, swaps: [])
        }

        headerBytes = Data(headerStr.utf8)
        var out = Data()
        out.reserveCapacity(headerBytes.count + bodyBytes.count)
        out.append(headerBytes)
        out.append(bodyBytes)
        return SwapResult(modified: out, swaps: swaps)
    }

    private static func preview(_ s: String) -> String {
        guard s.count > 8 else { return "***" }
        return String(s.prefix(4)) + "…" + String(s.suffix(4))
    }
}

public struct SwapResult: Sendable {
    public let modified: Data
    public let swaps: [SwapRecord]
}

public struct SwapRecord: Sendable {
    public let fakePreview: String
    public let realPreview: String
    public let host: String
}
