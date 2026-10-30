import Foundation

/// Any JSON value: QMP's arguments, replies and event payloads are open-ended.
// @port-skip linux-only: QMP plumbing; VZ has no JSON control protocol
public enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    // @port-skip linux-only: QMP plumbing
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    // @port-skip linux-only: QMP plumbing
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n):
            // Integers stay integers on the wire (QEMU rejects 1.0 for an int).
            if n.rounded() == n, abs(n) < 9.0e15 { try c.encode(Int64(n)) } else { try c.encode(n) }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    // @port-skip linux-only: QMP plumbing
    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    // @port-skip linux-only: QMP plumbing
    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    // @port-skip linux-only: QMP plumbing
    public var numberValue: Double? {
        if case .number(let n) = self { return n }
        return nil
    }

    /// Any Encodable as a JSONValue (typed QMP arguments).
    // @port-skip linux-only: QMP plumbing
    public init(encoding value: some Encodable) throws {
        self = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }

    /// This value decoded as `T` (typed QMP replies).
    // @port-skip linux-only: QMP plumbing
    public func decode<T: Decodable>(as type: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(self))
    }
}

// @port-skip linux-only: QMP plumbing
extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByDictionaryLiteral, ExpressibleByArrayLiteral {
    // @port-skip linux-only: QMP plumbing
    public init(stringLiteral value: String) { self = .string(value) }
    // @port-skip linux-only: QMP plumbing
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    // @port-skip linux-only: QMP plumbing
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    // @port-skip linux-only: QMP plumbing
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, b in b }))
    }
    // @port-skip linux-only: QMP plumbing
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}
