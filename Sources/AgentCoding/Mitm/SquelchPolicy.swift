import Foundation

/// Per-workspace Squelch setting (`Profile.squelch`).
public struct SquelchPolicy: Codable, Equatable, Sendable {
    public var enabled: Bool

    public init(enabled: Bool = false) { self.enabled = enabled }

    enum CodingKeys: String, CodingKey { case enabled }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if enabled { try c.encode(enabled, forKey: .enabled) }
    }
}

/// What Squelch did, as counts. Tokens are estimated as bytes / 4 (no
/// tokenizer — the share saved is reliable, the absolute
/// count approximate).
struct SquelchTally: Codable, Equatable, Sendable {
    /// Command outputs the model was sent, and how many of them were trimmed.
    var outputs = 0
    var trimmed = 0
    /// Their size as the commands printed them, and as the model read them.
    var rawBytes = 0
    var keptBytes = 0

    var savedBytes: Int { max(0, rawBytes - keptBytes) }
    var rawTokens: Int { rawBytes / 4 }
    var keptTokens: Int { keptBytes / 4 }
    var savedTokens: Int { savedBytes / 4 }
    /// Share of command output left out, 0…1.
    var savedFraction: Double { rawBytes > 0 ? Double(savedBytes) / Double(rawBytes) : 0 }
    var isEmpty: Bool { outputs == 0 }

    static func + (a: SquelchTally, b: SquelchTally) -> SquelchTally {
        SquelchTally(outputs: a.outputs + b.outputs, trimmed: a.trimmed + b.trimmed,
                     rawBytes: a.rawBytes + b.rawBytes, keptBytes: a.keptBytes + b.keptBytes)
    }
    static func - (a: SquelchTally, b: SquelchTally) -> SquelchTally {
        SquelchTally(outputs: a.outputs - b.outputs, trimmed: a.trimmed - b.trimmed,
                     rawBytes: a.rawBytes - b.rawBytes, keptBytes: a.keptBytes - b.keptBytes)
    }
}

/// A workspace's savings as its rows and headers show them: the total and
/// where most of it came from. What a host sends its fat clients.
struct SquelchSummary: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        var name: String
        var tally: SquelchTally
    }
    var total = SquelchTally()
    /// The commands that saved the most, most first.
    var commands: [Entry] = []
    /// The last days, oldest first ("2026-10-19").
    var days: [Entry] = []
}

/// How Squelch numbers read: "12.4K", "1.2M".
enum SquelchFormat {
    static func tokens(_ n: Int) -> String {
        switch n {
        case ..<1000: return "\(n)"
        case ..<10_000: return String(format: "%.1fK", Double(n) / 1000)
        case ..<1_000_000: return String(format: "%.0fK", Double(n) / 1000)
        default: return String(format: "%.1fM", Double(n) / 1_000_000)
        }
    }

    static func percent(_ f: Double) -> String { String(format: "%.0f%%", f * 100) }
}
