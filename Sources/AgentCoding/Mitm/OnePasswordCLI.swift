import Foundation

/// Thin wrapper around the 1Password `op` CLI. Resolves `op://vault/item/field`
/// secret references host-side so the real value never touches the guest — only
/// the reference is ever persisted. `op` owns auth (biometric / 1Password app
/// integration / `op signin`); we just shell out and capture the resolved secret.
public enum OnePasswordCLI {
    public enum OpError: Swift.Error, LocalizedError {
        case notInstalled
        case readFailed(ref: String, stderr: String)
        public var errorDescription: String? {
            switch self {
            case .notInstalled:
                return "The 1Password CLI (op) isn't installed or couldn't be found."
            case .readFailed(let ref, let stderr):
                return "1Password couldn't read \(ref): \(stderr)"
            }
        }
    }

    /// Docs link shown when `op` is missing.
    public static let installURL = "https://developer.1password.com/docs/cli/get-started/"

    /// Candidate absolute paths (Homebrew ARM/Intel, then /usr/bin), plus a
    /// `BROMURE_OP_PATH` override. The app's `Process` calls run un-sandboxed
    /// against the host FS, so probing with `isExecutableFile` works.
    public static func locate() -> URL? {
        let fm = FileManager.default
        if let override = ProcessInfo.processInfo.environment["BROMURE_OP_PATH"],
           fm.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }
        for p in ["/opt/homebrew/bin/op", "/usr/local/bin/op", "/usr/bin/op"] {
            if fm.isExecutableFile(atPath: p) { return URL(fileURLWithPath: p) }
        }
        return nil
    }

    public static var isInstalled: Bool { locate() != nil }

    /// If `raw` is a 1Password secret reference — bare `op://…` or the brace
    /// form `{{ op://… }}` that `.env.op` / `op inject` use — returns the
    /// normalized bare `op://…` path; otherwise nil.
    public static func reference(in raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("{{"), s.hasSuffix("}}") {
            s = String(s.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return s.hasPrefix("op://") ? s : nil
    }

    /// Resolve one `op://…` reference to its secret (trailing newline stripped).
    /// Throws `.notInstalled` when `op` is missing, `.readFailed` on any op error
    /// (not signed in, item/field not found, etc.).
    public static func read(_ ref: String) async throws -> String {
        guard let op = locate() else { throw OpError.notInstalled }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Swift.Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = op
                p.arguments = ["read", "--no-newline", ref]
                // Inherit the host env so op's biometric / session-token and
                // Homebrew paths resolve; `op read` is non-interactive.
                let out = Pipe(), err = Pipe()
                p.standardOutput = out
                p.standardError = err
                do {
                    try p.run()
                } catch {
                    cont.resume(throwing: OpError.readFailed(
                        ref: ref, stderr: error.localizedDescription))
                    return
                }
                p.waitUntilExit()
                let data = out.fileHandleForReading.readDataToEndOfFile()
                if p.terminationStatus == 0 {
                    cont.resume(returning: String(decoding: data, as: UTF8.self))
                } else {
                    let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    cont.resume(throwing: OpError.readFailed(
                        ref: ref, stderr: e.isEmpty ? "op exited \(p.terminationStatus)" : e))
                }
            }
        }
    }
}
