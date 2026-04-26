import Foundation

/// How aggressively bromure-ac records the proxy's traffic for a
/// profile. Higher levels store more — and bodies are AES-GCM-sealed
/// at rest with the SecretsVault master key, but they're still on
/// disk, so the user opts in.
public enum TraceLevel: String, Codable, CaseIterable, Sendable {
    /// Nothing recorded. Default.
    case off
    /// Per-request metadata only: timestamp, host, path, status,
    /// latency, bytes, swap report, leak warnings. No bodies.
    case activity
    /// Same as `.activity` plus full request + response bodies for
    /// well-known LLM hosts (Anthropic, OpenAI, Google AI, Cohere,
    /// Mistral, Perplexity, x.ai, Groq, Replicate, HuggingFace).
    case aiDetails
    /// Same as `.aiDetails` plus bodies for every host. Eats space
    /// fastest — gated by per-session 100 MB / total 5 GB caps.
    case all

    public var displayName: String {
        switch self {
        case .off:        return NSLocalizedString("Off", comment: "")
        case .activity:   return NSLocalizedString("Activity only", comment: "")
        case .aiDetails:  return NSLocalizedString("AI request details", comment: "")
        case .all:        return NSLocalizedString("Everything", comment: "")
        }
    }

    /// Hosts whose bodies are captured at the `.aiDetails` level.
    /// Substring match against the request's `Host` header.
    public static let aiHosts: [String] = [
        "anthropic.com",
        "openai.com",
        "googleapis.com",     // Gemini
        "google.com",         // GenAI APIs sometimes route here
        "cohere.com",
        "mistral.ai",
        "perplexity.ai",
        "x.ai",
        "groq.com",
        "replicate.com",
        "huggingface.co",
    ]

    /// True if a request to `host` should have its body captured at
    /// this level.
    public func capturesBodyForHost(_ host: String) -> Bool {
        switch self {
        case .off, .activity: return false
        case .all:            return true
        case .aiDetails:
            let lower = host.lowercased()
            return Self.aiHosts.contains { lower.contains($0) }
        }
    }

    /// True if any record (metadata or otherwise) should be written
    /// at this level.
    public var recordsActivity: Bool { self != .off }
}

/// One MITM exchange — what `HTTPMitmConnection.run()` produces and
/// `TraceStore` records. Only carries previews of secret values; the
/// full real bytes never enter this struct.
public struct TraceRecord: Codable, Identifiable, Sendable {
    public let id: UUID
    public let sessionID: UUID
    public let profileID: UUID
    public let timestamp: Date
    public let host: String
    public let port: Int
    public let method: String
    public let path: String
    public let statusCode: Int
    /// Pre-swap request size in bytes (= what the VM sent before our
    /// substitution). Captures the user's actual outbound footprint.
    public let requestBytes: Int
    public let responseBytes: Int
    /// Wall-clock duration from CONNECT received to response sent
    /// back through the TLS server. Includes upstream RTT.
    public let latencyMs: Double
    /// Tokens we substituted on the wire. Each entry has previews
    /// only — the real values stay in the in-memory swap map.
    public let swaps: [SwapEntry]
    /// Bearer/x-api-key values in the pre-swap request that are NOT
    /// known fakes — i.e. potential leaks the user should know about.
    public let leaks: [LeakEntry]
    /// True if request + response body files exist on disk for this
    /// record (gated by the session's TraceLevel and the host).
    public let bodyStored: Bool
    /// True if `ConversationParser.parse(...)` succeeded on the
    /// captured bodies — i.e. this record is a real AI chat
    /// exchange, not just any request to an AI host. The proxy sets
    /// this at record time so the inspector's "Conversations only"
    /// filter is a cheap boolean check (no on-disk parsing).
    /// Defaults false so old JSONL records (pre-flag) decode cleanly.
    public let isConversation: Bool

    public init(id: UUID = UUID(), sessionID: UUID, profileID: UUID,
                timestamp: Date = Date(), host: String, port: Int,
                method: String, path: String, statusCode: Int,
                requestBytes: Int, responseBytes: Int, latencyMs: Double,
                swaps: [SwapEntry], leaks: [LeakEntry],
                bodyStored: Bool, isConversation: Bool = false) {
        self.id = id
        self.sessionID = sessionID
        self.profileID = profileID
        self.timestamp = timestamp
        self.host = host
        self.port = port
        self.method = method
        self.path = path
        self.statusCode = statusCode
        self.requestBytes = requestBytes
        self.responseBytes = responseBytes
        self.latencyMs = latencyMs
        self.swaps = swaps
        self.leaks = leaks
        self.bodyStored = bodyStored
        self.isConversation = isConversation
    }

    enum CodingKeys: String, CodingKey {
        case id, sessionID, profileID, timestamp, host, port, method, path
        case statusCode, requestBytes, responseBytes, latencyMs
        case swaps, leaks, bodyStored, isConversation
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        sessionID = try c.decode(UUID.self, forKey: .sessionID)
        profileID = try c.decode(UUID.self, forKey: .profileID)
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        host = try c.decode(String.self, forKey: .host)
        port = try c.decode(Int.self, forKey: .port)
        method = try c.decode(String.self, forKey: .method)
        path = try c.decode(String.self, forKey: .path)
        statusCode = try c.decode(Int.self, forKey: .statusCode)
        requestBytes = try c.decode(Int.self, forKey: .requestBytes)
        responseBytes = try c.decode(Int.self, forKey: .responseBytes)
        latencyMs = try c.decode(Double.self, forKey: .latencyMs)
        swaps = try c.decode([SwapEntry].self, forKey: .swaps)
        leaks = try c.decode([LeakEntry].self, forKey: .leaks)
        bodyStored = try c.decode(Bool.self, forKey: .bodyStored)
        // Default false: pre-flag JSONL records won't have it.
        isConversation = try c.decodeIfPresent(Bool.self, forKey: .isConversation) ?? false
    }
}

/// A token swap that fired on the wire. Previews only — the swap
/// engine kept the real bytes in memory.
public struct SwapEntry: Codable, Sendable {
    public let header: String           // e.g. "Authorization", "x-api-key"
    public let fakePreview: String      // first/last 4 chars
    public let realPreview: String
    public init(header: String, fakePreview: String, realPreview: String) {
        self.header = header
        self.fakePreview = fakePreview
        self.realPreview = realPreview
    }
}

/// A bearer-style token in the pre-swap request that bromure didn't
/// recognise — potentially a real secret the user pasted directly
/// into the VM, bypassing the swap system.
public struct LeakEntry: Codable, Sendable {
    public enum Suspicion: String, Codable, Sendable {
        /// Token has a recognised secret prefix (sk-ant-, ghp_, etc.)
        /// but isn't one we minted.
        case knownPrefix
        /// Long opaque value in an auth header that doesn't match a
        /// well-known fake-prefix shape but smells like a credential.
        case opaqueToken
    }
    public let header: String       // e.g. "Authorization"
    public let valuePreview: String // first/last few chars
    public let suspicion: Suspicion
    public init(header: String, valuePreview: String, suspicion: Suspicion) {
        self.header = header
        self.valuePreview = valuePreview
        self.suspicion = suspicion
    }
}
