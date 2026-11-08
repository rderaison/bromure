import Foundation
import SandboxEngine

/// A workspace's control-socket sub-resources (`/profiles/{id}/…`) that read
/// or change its policy: revisions, the OpenShell advisor's proposals, and
/// the Sandbox drawer's one-click decisions. The macOS automation server and
/// the Linux daemon answer them alike.
enum ProfileSubRoutes {
    /// Control-socket route for a workspace's OpenShell policy revisions:
    ///   GET /profiles/{id}/policy/revisions        → every revision (no text)
    ///   GET /profiles/{id}/policy/revisions/{n}    → one revision, with its policy
    static func policyRevisionsRoute(directory: URL, method: String, sub: [String])
        -> (status: Int, body: [String: Any]) {
        guard method == "GET", sub.count >= 2, sub[1] == "revisions" else {
            return (405, ["error": "Use GET /policy/revisions[/{version}]"])
        }
        let iso = ISO8601DateFormatter()
        let all = PolicyHistory.shared.revisions(in: directory)
        func describe(_ r: PolicyHistory.Revision, withPolicy: Bool) -> [String: Any] {
            var d: [String: Any] = ["version": r.version, "hash": r.hash,
                                    "saved_at": iso.string(from: r.savedAt), "source": r.source]
            if withPolicy { d["policy"] = r.policy }
            return d
        }
        if sub.count == 3 {
            guard let n = Int(sub[2]), let r = all.first(where: { $0.version == n }) else {
                return (404, ["error": "No revision \(sub[2])"])
            }
            return (200, describe(r, withPolicy: true))
        }
        return (200, ["current": all.last?.version as Any, "revisions": all.reversed().map { describe($0, withPolicy: false) }])
    }

    /// Control-socket route for the OpenShell advisor's proposals — the
    /// same approve / reject the policy editor offers:
    ///   GET  /profiles/{id}/proposals                       → every proposal
    ///   POST /profiles/{id}/proposals/{proposal}/approve
    ///   POST /profiles/{id}/proposals/{proposal}/reject     {"reason": "…"}
    /// Runs on the automation server's thread.
    /// The Sandbox drawer's one-click decisions from a fat client, as its own
    /// window makes them here: `openshell-allow` (OpenShellAdvisor.allow) and
    /// `sandbox-path` (a filesystem path into the policy, at the next start).
    /// Runs on the automation server's thread. 200 {"ok": true}, else
    /// 400/409 {"error"}.
    static func sandboxDecisionRoute(
        profileID: UUID, _ action: String, body: [String: Any],
        allow: @escaping @Sendable (UUID, String, Int, String?) async -> String?,
        addPath: (UUID, String, Bool) -> String?
    ) -> (status: Int, body: [String: Any]) {
        switch action {
        case "openshell-allow":
            guard let host = body["host"] as? String, !host.isEmpty, host.count <= 253,
                  let port = body["port"] as? Int, (1...65535).contains(port) else {
                return (400, ["error": "host and port (1-65535) required"])
            }
            let exe = (body["exe"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(4096)) }
            let box = SendableBox<String?>(nil)
            let done = DispatchSemaphore(value: 0)
            Task.detached { box.value = await allow(profileID, host, port, exe); done.signal() }
            if done.wait(timeout: .now() + 30) == .timedOut { return (504, ["error": "Allowing \(host):\(port) timed out"]) }
            if let error = box.value { return (409, ["error": error]) }
            return (200, ["ok": true])
        case "sandbox-path":
            guard let path = body["path"] as? String, path.hasPrefix("/"), path.count <= 4096,
                  !path.contains("\n"), !path.contains("\0") else {
                return (400, ["error": "an absolute path required"])
            }
            if let error = addPath(profileID, path, (body["readWrite"] as? Bool) ?? false) {
                return (409, ["error": error])
            }
            return (200, ["ok": true])
        default:
            return (404, ["error": "Unknown sandbox decision"])
        }
    }

    static func advisorProposalsRoute(profileID: UUID, method: String, sub: [String],
                                                  body: [String: Any], advisor: OpenShellAdvisor = .shared)
        -> (status: Int, body: [String: Any]) {
        func describe(_ p: OpenShellAdvisor.Proposal) -> [String: Any] {
            var d: [String: Any] = [
                "id": p.id, "status": p.status.rawValue, "source": p.source, "intent": p.intent,
                "host": p.host, "port": Int(p.port), "rule_name": p.rule.name,
                "binaries": p.rule.binaries, "findings": p.findings, "auto": p.auto,
                "created_at": ISO8601DateFormatter().string(from: p.createdAt),
            ]
            if let r = p.rejectionReason { d["rejection_reason"] = r }
            if let e = p.applicationError { d["application_error"] = e }
            return d
        }
        switch (method, sub.count) {
        case ("GET", 1):
            return (200, ["proposals": advisor.proposals(for: profileID).map(describe),
                          "packages": advisor.packageRequests(for: profileID).map(advisor.describe)])
        case ("POST", 3) where sub[1].hasPrefix("pkg-") && (sub[2] == "approve" || sub[2] == "reject"):
            // A system-package request: approve starts the install and returns.
            let id = sub[1]
            guard let r = advisor.packageRequests(for: profileID).first(where: { $0.id == id }) else {
                return (404, ["error": "No package request \(id)"])
            }
            guard r.status == .pending else {
                return (409, ["error": "Package request \(id) is already \(r.status.rawValue)", "request": advisor.describe(r)])
            }
            if sub[2] == "reject" {
                advisor.rejectPackages(id: id, profileID: profileID, reason: (body["reason"] as? String) ?? "")
            } else {
                Task.detached { await advisor.approvePackages(id: id, profileID: profileID) }
            }
            return (200, ["ok": true, "request": advisor.packageRequests(for: profileID).first { $0.id == id }.map(advisor.describe) ?? [:]])
        case ("POST", 3) where sub[2] == "approve" || sub[2] == "reject":
            let id = sub[1]
            guard let current = advisor.proposals(for: profileID).first(where: { $0.id == id }) else {
                return (404, ["error": "No proposal \(id)"])
            }
            guard current.status == .pending else {
                return (409, ["error": "Proposal \(id) is already \(current.status.rawValue)", "proposal": describe(current)])
            }
            if sub[2] == "reject" {
                advisor.reject(id: id, profileID: profileID, reason: (body["reason"] as? String) ?? "")
            } else {
                let done = DispatchSemaphore(value: 0)
                Task.detached { await advisor.approve(id: id, profileID: profileID); done.signal() }
                if done.wait(timeout: .now() + 30) == .timedOut {
                    return (504, ["error": "Approving \(id) timed out"])
                }
            }
            let after = advisor.proposals(for: profileID).first { $0.id == id }
            return (200, ["ok": true, "proposal": after.map(describe) ?? [:]])
        default:
            return (405, ["error": "Use GET /proposals or POST /proposals/{id}/approve|reject"])
        }
    }
}

/// A value an async task hands back to a thread that waits on a semaphore
/// (the automation server's request thread).
final class SendableBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}
