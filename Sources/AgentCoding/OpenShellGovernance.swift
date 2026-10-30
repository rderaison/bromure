import Foundation
import SandboxEngine

/// Organization-level OpenShell governance: a boundary policy (the most any
/// workspace may allow) plus managed defaults, set locally or pushed by
/// bromure.io to enrolled installs (`OpenShellManagedPolicySync`).
///
/// With a boundary in force:
///  - a workspace's OpenShell policy (plus its attached provider profiles)
///    must be `within_boundary` — checked by NVIDIA's `openshell-prover` when
///    installed, else by `OpenShellBoundary`'s conservative native check; a
///    policy that doesn't pass can't be saved, and one already saved fails
///    closed at session start;
///  - a workspace with NO OpenShell policy runs under the boundary itself;
///  - the policy advisor can't approve a rule that would leave the boundary.
/// Bromure's own provider layer (the agents' model APIs, injected
/// credentials) isn't part of the check: those destinations are governed by
/// which agents and credentials the organization configures.
public final class OpenShellGovernance: @unchecked Sendable {
    public static let shared = OpenShellGovernance()
    public static let changedNotification = Notification.Name("OpenShellGovernanceChanged")

    static let localBoundaryKey = "openshell.boundaryPolicy"
    static let managedKey = "openshell.managedPolicy"

    /// What bromure.io pushes (cached so it applies offline too).
    public struct Managed: Codable, Equatable, Sendable {
        public var boundaryYAML: String?
        public var defaultPolicyYAML: String?
        public var requireStrictCredentials: Bool = false
        public var requireStrictSandbox: Bool = false
        /// Minimum kernel sentry requirement for every workspace
        /// (`best_effort` / `hard`); nil = none.
        public var minKernelSentry: String?
        /// Highest advisor mode workspaces may use (`off` / `review` / `auto`).
        public var maxAdvisorMode: String?
        /// Upload the agent's reasoning behind each tool call
        /// (`agent.reasoning`, NETWORK_LINEAGE.md). Off unless the org opts in.
        public var captureAgentReasoning: Bool = false
        public var updatedAt: String?
    }

    private let lock = NSLock()
    private var cache: [String: OpenShellBoundary.Result] = [:]

    // MARK: Sources

    public var managed: Managed? {
        guard let d = ACDefaults.standard.data(forKey: Self.managedKey) else { return nil }
        return try? JSONDecoder().decode(Managed.self, from: d)
    }

    public func setManaged(_ m: Managed?) {
        if let m, let d = try? JSONEncoder().encode(m) {
            ACDefaults.standard.set(d, forKey: Self.managedKey)
        } else {
            ACDefaults.standard.removeObject(forKey: Self.managedKey)
        }
        lock.lock(); cache.removeAll(); lock.unlock()
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.changedNotification, object: nil) }
    }

    /// The boundary in force: the organization's (managed) wins over a local one.
    public var boundaryYAML: String? {
        if let m = managed?.boundaryYAML, !m.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return m }
        let local = ACDefaults.standard.string(forKey: Self.localBoundaryKey) ?? ""
        return local.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : local
    }

    public var boundaryIsManaged: Bool {
        !(managed?.boundaryYAML ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func setLocalBoundary(_ yaml: String?) {
        ACDefaults.standard.set(yaml ?? "", forKey: Self.localBoundaryKey)
        lock.lock(); cache.removeAll(); lock.unlock()
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.changedNotification, object: nil) }
    }

    public var boundary: OpenShellPolicy? {
        boundaryYAML.flatMap { try? OpenShellPolicy.parse($0) }
    }

    // MARK: Checking

    /// The candidate the boundary is checked against: the authored policy
    /// plus attached provider-profile rules (renamed out of the reserved
    /// `_provider_` namespace so the prover accepts the file).
    static func candidateYAML(policy: String, providerRules: [OpenShellPolicy.NetworkRule]) -> String {
        var text = policy
        for var r in providerRules {
            r.key = String(r.key.dropFirst("_".count))                // provider_<name>
            r.name = r.key
            if let t = try? OpenShellPolicy.insertingRules(OpenShellPolicy.yaml(rule: r), into: text) { text = t }
        }
        return text
    }

    /// Check a workspace policy (YAML) against the boundary in force. nil =
    /// no boundary (nothing to check).
    public func check(policyYAML: String, providerRules: [OpenShellPolicy.NetworkRule] = []) -> OpenShellBoundary.Result? {
        guard let boundaryText = boundaryYAML else { return nil }
        let candidate = Self.candidateYAML(policy: policyYAML, providerRules: providerRules)
        let key = "\(candidate.hashValue)|\(boundaryText.hashValue)"
        lock.lock()
        if let hit = cache[key] { lock.unlock(); return hit }
        lock.unlock()
        let result: OpenShellBoundary.Result
        if let prover = OpenShellProver.run(candidate: candidate, boundary: boundaryText) {
            result = prover
        } else {
            do {
                result = OpenShellBoundary.check(candidate: try OpenShellPolicy.parse(candidate),
                                                 boundary: try OpenShellPolicy.parse(boundaryText))
            } catch {
                result = .error("\(error)")
            }
        }
        lock.lock(); cache[key] = result; lock.unlock()
        return result
    }

    /// Clamp a workspace's advisor mode to the organization's maximum.
    public func effectiveAdvisorMode(_ requested: OpenShellAdvisorMode) -> OpenShellAdvisorMode {
        guard let max = managed?.maxAdvisorMode.flatMap(OpenShellAdvisorMode.init(rawValue:)) else { return requested }
        let order: [OpenShellAdvisorMode] = [.off, .review, .auto]
        return order.firstIndex(of: requested)! <= order.firstIndex(of: max)! ? requested : max
    }
}

/// NVIDIA's `openshell-prover` (Homebrew / Debian / RPM packages), when it's
/// on this Mac: `check candidate --boundary b --output json`.
enum OpenShellProver {
    static var executable: String? {
        let env = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let dirs = env.split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin"]
        return dirs.map { $0 + "/openshell-prover" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func run(candidate: String, boundary: String, timeout: TimeInterval = 15) -> OpenShellBoundary.Result? {
        guard let exe = executable else { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("osprover-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try candidate.write(to: dir.appendingPathComponent("candidate.yaml"), atomically: true, encoding: .utf8)
            try boundary.write(to: dir.appendingPathComponent("boundary.yaml"), atomically: true, encoding: .utf8)
        } catch { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["check", dir.appendingPathComponent("candidate.yaml").path,
                       "--boundary", dir.appendingPathComponent("boundary.yaml").path,
                       "--output", "json"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(timeout + 5)
        while p.isRunning, Date() < deadline { usleep(50_000) }
        if p.isRunning { p.terminate(); return .unsupported(reason: "openshell-prover timed out") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return parse(data)
    }

    static func parse(_ data: Data) -> OpenShellBoundary.Result? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = obj["result"] as? String else { return nil }
        let reason = (obj["reason"] as? String) ?? (obj["reason_code"] as? String) ?? result
        switch result {
        case "within_boundary": return .withinBoundary
        case "exceeds_boundary":
            let ce = obj["counterexample"].flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
                .map { String(decoding: $0, as: UTF8.self) } ?? "(no counterexample)"
            return .exceedsBoundary(counterexample: ce)
        case "unsupported", "inconclusive": return .unsupported(reason: reason)
        default: return .error(reason)
        }
    }
}

/// Pulls the organization's OpenShell policy for an enrolled install:
/// `GET /v1/installs/:installId/openshell-policy` (install bearer), riding
/// the enrollment heartbeat. 404 / an empty document clears it; a network
/// failure keeps the cached copy (the policy must hold offline too).
enum OpenShellManagedPolicySync {
    static func fetch() async {
        guard let install = BACEnrollmentStore.load(),
              let token = BACEnrollmentStore.loadInstallToken() else {
            if OpenShellGovernance.shared.managed != nil { OpenShellGovernance.shared.setManaged(nil) }
            return
        }
        let url = install.serverURL.appendingPathComponent("v1/installs/\(install.installId)/openshell-policy")
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 20
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else { return }
        if http.statusCode == 404 {
            if OpenShellGovernance.shared.managed != nil { OpenShellGovernance.shared.setManaged(nil) }
            return
        }
        guard http.statusCode == 200 else { return }
        let managed = decode(data)
        if managed != OpenShellGovernance.shared.managed { OpenShellGovernance.shared.setManaged(managed) }
    }

    static func decode(_ data: Data) -> OpenShellGovernance.Managed? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func text(_ k: String) -> String? {
            guard let s = o[k] as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return s
        }
        var m = OpenShellGovernance.Managed()
        m.boundaryYAML = text("boundary_yaml")
        m.defaultPolicyYAML = text("default_policy_yaml")
        m.requireStrictCredentials = o["require_strict_credentials"] as? Bool ?? false
        m.requireStrictSandbox = o["require_strict_sandbox"] as? Bool ?? false
        m.maxAdvisorMode = text("max_advisor_mode")
        m.minKernelSentry = text("min_kernel_sentry")
        m.captureAgentReasoning = o["capture_agent_reasoning"] as? Bool ?? false
        m.updatedAt = text("updated_at")
        let empty = m.boundaryYAML == nil && m.defaultPolicyYAML == nil && !m.requireStrictCredentials
            && !m.requireStrictSandbox && m.maxAdvisorMode == nil && m.minKernelSentry == nil
            && !m.captureAgentReasoning
        return empty ? nil : m
    }
}

extension OpenShellGovernance {
    /// The organization's minimum kernel sentry (bromure.io managed policy):
    /// the lowest a workspace may run with — `.off` when none is set. A
    /// workspace's own setting below it is raised to it
    /// (`Profile.effectiveKernelSentry`), so "turning it off" goes to this.
    var kernelSentryFloor: KernelSentryMode {
        managed?.minKernelSentry.flatMap(KernelSentryMode.init(rawValue:)) ?? .off
    }

    /// A save refused because its OpenShell policy leaves the organization
    /// boundary.
    struct BoundaryRefusal: Error, LocalizedError, CustomStringConvertible {
        let summary: String
        var description: String { "outside the organization boundary — \(summary)" }
        var errorDescription: String? { description }
    }

    /// The boundary verdict on saving `profile` over `editing`: nil = fine.
    /// Every path that persists a workspace (editor, API, advisor, the
    /// Sandbox drawer's Files Allow) goes through this, so none can skip the
    /// boundary. Only a policy that changed is judged: an unrelated edit of a
    /// workspace saved under an older boundary isn't blocked by it.
    func refusal(saving profile: Profile, editing: Profile?) -> BoundaryRefusal? {
        guard profile.usesOpenShellPolicy else { return nil }
        if let editing, editing.networkPolicy == profile.networkPolicy,
           editing.openShellProviderRules == profile.openShellProviderRules { return nil }
        guard let result = check(policyYAML: profile.networkPolicy,
                                 providerRules: profile.openShellProviderRules),
              !result.passed else { return nil }
        return BoundaryRefusal(summary: result.summary)
    }
}
