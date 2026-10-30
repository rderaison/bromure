// Census shim: just enough of Apple's `os` (Logger, OSLog, os_log) to typecheck
// logging call sites on Linux. Not a real logger: the real port uses swift-log
// or stderr behind the same names.
@_exported import Foundation

public enum OSLogType: Sendable { case `default`, info, debug, error, fault }
public struct OSLogPrivacy: Sendable {
    public static let `public` = OSLogPrivacy(), `private` = OSLogPrivacy(), auto = OSLogPrivacy(), sensitive = OSLogPrivacy()
    public static func `private`(mask: OSLogPrivacy.Mask) -> OSLogPrivacy { OSLogPrivacy() }
    public static func sensitive(mask: OSLogPrivacy.Mask) -> OSLogPrivacy { OSLogPrivacy() }
    public struct Mask: Sendable { public static let hash = Mask(), none = Mask() }
}
public struct OSLogIntegerFormatting: Sendable {
    public static let decimal = OSLogIntegerFormatting(), hex = OSLogIntegerFormatting(), octal = OSLogIntegerFormatting()
    public static func decimal(minDigits: Int) -> OSLogIntegerFormatting { .init() }
    public static func hex(explicitPositiveSign: Bool = false, includePrefix: Bool = false, uppercase: Bool = false, minDigits: Int = 0) -> OSLogIntegerFormatting { .init() }
}
public struct OSLogFloatFormatting: Sendable {
    public static let fixed = OSLogFloatFormatting()
    public static func fixed(precision: Int) -> OSLogFloatFormatting { .init() }
}
public struct OSLogStringAlignment: Sendable {
    public static let none = OSLogStringAlignment()
    public static func left(columns: Int) -> OSLogStringAlignment { .init() }
    public static func right(columns: Int) -> OSLogStringAlignment { .init() }
}
public struct OSLogMessage: ExpressibleByStringInterpolation, ExpressibleByStringLiteral, Sendable {
    public var text = ""
    public init(stringLiteral value: String) { text = value }
    public init(stringInterpolation: Interpolation) { text = stringInterpolation.text }
    public struct Interpolation: StringInterpolationProtocol {
        var text = ""
        public init(literalCapacity: Int, interpolationCount: Int) {}
        public mutating func appendLiteral(_ s: String) { text += s }
        public mutating func appendInterpolation<T>(_ v: @autoclosure () -> T, privacy: OSLogPrivacy = .auto, align: OSLogStringAlignment = .none) { text += "\(v())" }
        public mutating func appendInterpolation<T: BinaryInteger>(_ v: @autoclosure () -> T, format: OSLogIntegerFormatting, align: OSLogStringAlignment = .none, privacy: OSLogPrivacy = .auto) { text += "\(v())" }
        public mutating func appendInterpolation<T: BinaryFloatingPoint>(_ v: @autoclosure () -> T, format: OSLogFloatFormatting, align: OSLogStringAlignment = .none, privacy: OSLogPrivacy = .auto) { text += "\(v())" }
    }
}
public struct Logger: Sendable {
    public init() {}
    public init(subsystem: String, category: String) {}
    public init(_ log: OSLog) {}
    public func log(_ m: OSLogMessage) {}
    public func log(level: OSLogType, _ m: OSLogMessage) {}
    public func trace(_ m: OSLogMessage) {}
    public func debug(_ m: OSLogMessage) {}
    public func info(_ m: OSLogMessage) {}
    public func notice(_ m: OSLogMessage) {}
    public func warning(_ m: OSLogMessage) {}
    public func error(_ m: OSLogMessage) {}
    public func critical(_ m: OSLogMessage) {}
    public func fault(_ m: OSLogMessage) {}
}
public final class OSLog: @unchecked Sendable {
    public static let `default` = OSLog(subsystem: "", category: "")
    public static let disabled = OSLog(subsystem: "", category: "")
    public init(subsystem: String, category: String) {}
}
public func os_log(_ message: StaticString, log: OSLog = .default, type: OSLogType = .default, _ args: any CVarArg...) {}
public func os_log(_ type: OSLogType, log: OSLog = .default, _ message: OSLogMessage) {}
public func os_log(_ message: OSLogMessage) {}
