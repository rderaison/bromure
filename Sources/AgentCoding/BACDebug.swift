import Foundation

/// Stderr logger gated on `BROMURE_AC_DEBUG=1`. Used by the cloud-events
/// path (proxy hooks → LLMEventExtractor → BACEventEmitter →
/// BACCloudUploader) so we can pinpoint hangs without leaving chatty
/// output in shipping builds.
enum BACDebug {
    static let enabled: Bool = {
        let env = ProcessInfo.processInfo.environment
        if let v = env["BROMURE_AC_DEBUG"], v == "1" || v.lowercased() == "true" {
            return true
        }
        return false
    }()

    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func log(_ tag: String, _ message: @autoclosure () -> String) {
        guard enabled else { return }
        let line = "[\(formatter.string(from: Date()))] \(tag) \(message())\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    /// Returns the wall-clock seconds since `start`, formatted to ms with
    /// one decimal — for inline duration tags ("took=12.3ms").
    static func ms(_ start: Date) -> String {
        let dt = Date().timeIntervalSince(start) * 1000
        return String(format: "%.1fms", dt)
    }
}
