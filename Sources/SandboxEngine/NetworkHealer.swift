import Foundation

/// Repairs macOS's shared-networking stack when vmnet's NAT path gets wedged.
///
/// macOS's `vmnet` shared mode (the backing for `VZNATNetworkDeviceAttachment`)
/// occasionally gets into a state where guests get no DHCP lease, or get a lease
/// but no traffic flows. The known fix is to kickstart the LaunchDaemons that
/// own the stack:
///   - `system/com.apple.bootpd` (DHCP — may not exist on all macOS versions)
///   - `system/com.apple.NetworkSharing` (umbrella vmnet/NAT daemon)
///
/// kickstart needs root, so we shell out to `osascript` with
/// `do shell script "..." with administrator privileges`. That goes through
/// Authorization Services and shows a single system password prompt — no TCC
/// for Accessibility/Automation is required.
public actor NetworkHealer {
    public static let shared = NetworkHealer()

    public enum Action: Sendable {
        /// DHCP only — bootpd kickstart. No-op on macOS versions where bootpd
        /// is not a registered launchd label (we tolerate the failure).
        case dhcp
        /// NAT only — NetworkSharing kickstart. The umbrella fix.
        case nat
        /// Both — for "no IP at all" cases.
        case both
    }

    private var inflight: Task<Bool, Never>?

    public func repair(_ action: Action) async -> Bool {
        if let inflight {
            return await inflight.value
        }
        let task = Task<Bool, Never> { [action] in
            await Self.runRepair(action)
        }
        inflight = task
        let result = await task.value
        inflight = nil
        return result
    }

    private static func runRepair(_ action: Action) async -> Bool {
        // Build the shell pipeline. bootpd may not be a registered service on
        // newer macOS — swallow its failure so NetworkSharing still runs.
        let parts: [String]
        switch action {
        case .dhcp:
            parts = ["launchctl kickstart -k system/com.apple.bootpd 2>/dev/null || true"]
        case .nat:
            parts = ["launchctl kickstart -k system/com.apple.NetworkSharing"]
        case .both:
            parts = [
                "launchctl kickstart -k system/com.apple.bootpd 2>/dev/null || true",
                "launchctl kickstart -k system/com.apple.NetworkSharing"
            ]
        }
        let shell = parts.joined(separator: "; ")

        // Escape for AppleScript string literal: backslash, then double-quote.
        let escaped = shell
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"

        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", script]
                let stderr = Pipe()
                let stdout = Pipe()
                process.standardError = stderr
                process.standardOutput = stdout
                do {
                    try process.run()
                    process.waitUntilExit()
                    if process.terminationStatus == 0 {
                        print("[NetworkHealer] repair succeeded (\(action))")
                        cont.resume(returning: true)
                    } else {
                        let errStr = String(
                            data: stderr.fileHandleForReading.readDataToEndOfFile(),
                            encoding: .utf8
                        ) ?? ""
                        // User-cancelled the auth prompt → osascript returns -128.
                        print("[NetworkHealer] osascript exit \(process.terminationStatus): \(errStr.trimmingCharacters(in: .whitespacesAndNewlines))")
                        cont.resume(returning: false)
                    }
                } catch {
                    print("[NetworkHealer] failed to spawn osascript: \(error)")
                    cont.resume(returning: false)
                }
            }
        }
    }
}
