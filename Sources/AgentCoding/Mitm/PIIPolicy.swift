import Foundation

/// Per-workspace PII protection: personal data in what the agent sends to its
/// model is swapped for stand-ins on the host, and the real values are put
/// back in the replies. The provider never sees them; the agent never sees
/// the stand-ins.
public struct PIIPolicy: Codable, Equatable, Sendable {
    public var enabled: Bool
    /// People's names.
    public var names: Bool
    /// Email addresses and phone numbers.
    public var contact: Bool
    /// Payment cards, bank accounts, routing and tax numbers.
    public var financial: Bool
    /// SSNs, passports, driver's licenses and other government IDs.
    public var governmentIDs: Bool
    /// Street addresses (city, state and postal code are kept).
    public var addresses: Bool

    public init(enabled: Bool = false, names: Bool = true, contact: Bool = true,
                financial: Bool = true, governmentIDs: Bool = true, addresses: Bool = true) {
        self.enabled = enabled
        self.names = names
        self.contact = contact
        self.financial = financial
        self.governmentIDs = governmentIDs
        self.addresses = addresses
    }

    public var isActive: Bool {
        enabled && (names || contact || financial || governmentIDs || addresses)
    }

    // MARK: Codable (tolerant; only non-defaults are written)

    enum CodingKeys: String, CodingKey {
        case enabled, names, contact, financial, governmentIDs, addresses
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        names = try c.decodeIfPresent(Bool.self, forKey: .names) ?? true
        contact = try c.decodeIfPresent(Bool.self, forKey: .contact) ?? true
        financial = try c.decodeIfPresent(Bool.self, forKey: .financial) ?? true
        governmentIDs = try c.decodeIfPresent(Bool.self, forKey: .governmentIDs) ?? true
        addresses = try c.decodeIfPresent(Bool.self, forKey: .addresses) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if enabled { try c.encode(enabled, forKey: .enabled) }
        if !names { try c.encode(names, forKey: .names) }
        if !contact { try c.encode(contact, forKey: .contact) }
        if !financial { try c.encode(financial, forKey: .financial) }
        if !governmentIDs { try c.encode(governmentIDs, forKey: .governmentIDs) }
        if !addresses { try c.encode(addresses, forKey: .addresses) }
    }
}
