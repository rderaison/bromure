import AppKit
import SwiftUI
import SandboxEngine

/// A policy-advisor proposal as the Sandbox drawer shows it: this Mac's
/// advisor's, or a fat client's host's, over its control socket.
struct DrawerProposal: Identifiable, Equatable {
    let id: String
    let host: String
    let port: Int
    let source: String
    let intent: String
    let binaries: [String]
    let findings: [String]
    let status: OpenShellAdvisor.Status

    init(id: String, host: String, port: Int, source: String, intent: String,
         binaries: [String], findings: [String], status: OpenShellAdvisor.Status) {
        self.id = id; self.host = host; self.port = port; self.source = source; self.intent = intent
        self.binaries = binaries; self.findings = findings; self.status = status
    }

    init(_ p: OpenShellAdvisor.Proposal) {
        self.init(id: p.id, host: p.host, port: Int(p.port), source: p.source, intent: p.intent,
                  binaries: p.rule.binaries, findings: p.findings, status: p.status)
    }

    /// From `GET /profiles/{id}/proposals`' `proposals` (the advisor route's describe).
    init?(wire d: [String: Any]) {
        guard let id = d["id"] as? String, let status = OpenShellAdvisor.Status(rawValue: d["status"] as? String ?? "")
        else { return nil }
        self.init(id: id, host: d["host"] as? String ?? "?", port: d["port"] as? Int ?? 0,
                  source: d["source"] as? String ?? "", intent: d["intent"] as? String ?? "",
                  binaries: d["binaries"] as? [String] ?? [], findings: d["findings"] as? [String] ?? [],
                  status: status)
    }
}

/// A system-package request as the drawer shows it.
struct DrawerPackage: Identifiable, Equatable {
    let id: String
    let packages: [String]
    let status: OpenShellAdvisor.PackageRequest.Status
    let exitCode: Int?
    let output: String

    init(id: String, packages: [String], status: OpenShellAdvisor.PackageRequest.Status, exitCode: Int?, output: String) {
        self.id = id; self.packages = packages; self.status = status; self.exitCode = exitCode; self.output = output
    }

    init(_ r: OpenShellAdvisor.PackageRequest) {
        self.init(id: r.id, packages: r.packages, status: r.status, exitCode: r.exitCode, output: r.output)
    }

    /// From the route's `packages` (the advisor's describe).
    init?(wire d: [String: Any]) {
        guard let id = d["id"] as? String,
              let status = OpenShellAdvisor.PackageRequest.Status(rawValue: d["status"] as? String ?? "") else { return nil }
        self.init(id: id, packages: d["packages"] as? [String] ?? [], status: status,
                  exitCode: d["exit_code"] as? Int, output: d["output"] as? String ?? "")
    }
}

/// What the Sandbox drawer reads and changes: this Mac's own workspaces, or a
/// fat client's host's (where every decision is made on the host).
@MainActor
protocol PolicyDrawerBackend: AnyObject {
    /// The timeline's `machine` for this backend's events (nil = this Mac).
    var machine: String? { get }
    func profile(_ id: UUID) -> Profile?
    func proposals(_ id: UUID) -> [DrawerProposal]
    func packages(_ id: UUID) -> [DrawerPackage]
    /// Bring the workspace's profile and proposals up to date (a host: fetch).
    func refresh(_ id: UUID)
    func editFirewall(_ edit: FirewallRuleActions.Edit, profileID: UUID) async -> Bool
    /// nil = allowed; else why not.
    func allowOpenShell(profileID: UUID, host: String, port: Int, exe: String?) async -> String?
    /// nil = added; else why not.
    func addSandboxPath(profileID: UUID, path: String, readWrite: Bool) async -> String?
    func restart(_ id: UUID)
    func decideProposal(id: String, profileID: UUID, approve: Bool)
    func decidePackages(id: String, profileID: UUID, approve: Bool)
}

/// This Mac: the app's own profiles and advisor.
@MainActor
final class LocalPolicyDrawerBackend: PolicyDrawerBackend {
    static let shared = LocalPolicyDrawerBackend()
    private var delegate: ACAppDelegate? { NSApp.delegate as? ACAppDelegate }

    var machine: String? { nil }
    func profile(_ id: UUID) -> Profile? { delegate?.profiles.first { $0.id == id } }
    func proposals(_ id: UUID) -> [DrawerProposal] { OpenShellAdvisor.shared.proposals(for: id).map(DrawerProposal.init) }
    func packages(_ id: UUID) -> [DrawerPackage] { OpenShellAdvisor.shared.packageRequests(for: id).map(DrawerPackage.init) }
    func refresh(_ id: UUID) {}
    func editFirewall(_ edit: FirewallRuleActions.Edit, profileID: UUID) async -> Bool {
        delegate?.applyFirewallEdit(edit, profileID: profileID) == true
    }
    func allowOpenShell(profileID: UUID, host: String, port: Int, exe: String?) async -> String? {
        await OpenShellAdvisor.shared.allow(profileID: profileID, host: host, port: port, exe: exe)
    }
    func addSandboxPath(profileID: UUID, path: String, readWrite: Bool) async -> String? {
        delegate?.addSandboxPath(profileID: profileID, path: path, readWrite: readWrite)
            ?? (delegate == nil ? "unavailable" : nil)
    }
    func restart(_ id: UUID) { delegate?.restartProfile(id) }
    func decideProposal(id: String, profileID: UUID, approve: Bool) {
        if approve { Task { await OpenShellAdvisor.shared.approve(id: id, profileID: profileID) } }
        else { OpenShellAdvisor.shared.reject(id: id, profileID: profileID, reason: "") }
    }
    func decidePackages(id: String, profileID: UUID, approve: Bool) {
        if approve { Task.detached { await OpenShellAdvisor.shared.approvePackages(id: id, profileID: profileID) } }
        else { OpenShellAdvisor.shared.rejectPackages(id: id, profileID: profileID, reason: "") }
    }
}

/// A fat client's host: the full profile and the advisor's proposals fetched
/// from its control socket, every decision sent there (the host's advisor,
/// firewall and sandbox decide, as they do for its own window).
@MainActor
@Observable
final class RemotePolicyDrawerBackend: PolicyDrawerBackend {
    @ObservationIgnored private weak var controller: RemoteHostController?
    private(set) var profiles: [UUID: Profile] = [:]
    private(set) var proposalsBy: [UUID: [DrawerProposal]] = [:]
    private(set) var packagesBy: [UUID: [DrawerPackage]] = [:]

    init(controller: RemoteHostController) { self.controller = controller }

    var machine: String? { controller?.securityMirrorKey }

    /// The host's full profile once fetched; its mirrored summary until then
    /// (enough for the name, not for the rules).
    func profile(_ id: UUID) -> Profile? { profiles[id] ?? controller?.profilesByID[id] }
    func proposals(_ id: UUID) -> [DrawerProposal] { proposalsBy[id] ?? [] }
    func packages(_ id: UUID) -> [DrawerPackage] { packagesBy[id] ?? [] }

    func refresh(_ id: UUID) {
        let seg = ControlClient.encodeSegment(id.uuidString)
        Task {
            if let r = await call("GET", "/profiles/\(seg)?full=1"), r.status == 200,
               let p = Self.decodeProfile(r.json) {
                profiles[id] = p
            }
            if let r = await call("GET", "/profiles/\(seg)/proposals"), r.status == 200 {
                proposalsBy[id] = (r.json["proposals"] as? [[String: Any]] ?? []).compactMap(DrawerProposal.init(wire:))
                packagesBy[id] = (r.json["packages"] as? [[String: Any]] ?? []).compactMap(DrawerPackage.init(wire:))
            }
        }
    }

    func editFirewall(_ edit: FirewallRuleActions.Edit, profileID: UUID) async -> Bool {
        // The edit itself, applied by the host to the rules it holds then --
        // not a whole document edited here, which a concurrent edit (another
        // Allow, the editor, an expiry) between the read and the commit lost.
        let r = await call("POST", "/profiles/\(ControlClient.encodeSegment(profileID.uuidString))/firewall-edit",
                           body: edit.wire)
        refresh(profileID)
        return Self.editSucceeded(r)
    }

    /// The host made the edit (or it already held): a 200 that says ok. A
    /// host answered ok for edits it couldn't make; status alone isn't
    /// enough.
    nonisolated static func editSucceeded(_ r: ControlClient.Response?) -> Bool {
        guard let r, r.status == 200 else { return false }
        return r.json["ok"] as? Bool == true
    }

    func allowOpenShell(profileID: UUID, host: String, port: Int, exe: String?) async -> String? {
        var body: [String: Any] = ["host": host, "port": port]
        if let exe { body["exe"] = exe }
        let r = await call("POST", "/profiles/\(ControlClient.encodeSegment(profileID.uuidString))/openshell-allow", body: body)
        refresh(profileID)
        return Self.failure(r)
    }

    func addSandboxPath(profileID: UUID, path: String, readWrite: Bool) async -> String? {
        let r = await call("POST", "/profiles/\(ControlClient.encodeSegment(profileID.uuidString))/sandbox-path",
                           body: ["path": path, "readWrite": readWrite])
        refresh(profileID)
        return Self.failure(r)
    }

    func restart(_ id: UUID) { controller?.restartWorkspace(id) }

    func decideProposal(id: String, profileID: UUID, approve: Bool) {
        Task {
            _ = await call("POST", "/profiles/\(ControlClient.encodeSegment(profileID.uuidString))/proposals/"
                           + "\(ControlClient.encodeSegment(id))/\(approve ? "approve" : "reject")", body: [:])
            refresh(profileID)
        }
    }

    func decidePackages(id: String, profileID: UUID, approve: Bool) {
        decideProposal(id: id, profileID: profileID, approve: approve)   // the route tells them apart (pkg-)
    }

    /// One request to the host, off the main actor.
    private func call(_ method: String, _ path: String, body: [String: Any]? = nil) async -> ControlClient.Response? {
        guard let host = controller?.host else { return nil }
        return await Task.detached(priority: .userInitiated) {
            try? RemoteTransport.client(for: host).request(method, path, body: body, recvTimeoutSeconds: 40)
        }.value
    }

    /// nil when the host said ok; else what it said, or why it couldn't be asked.
    nonisolated static func failure(_ r: ControlClient.Response?) -> String? {
        guard let r else { return NSLocalizedString("The host didn't answer.", comment: "sandbox drawer, fat client") }
        if r.status == 200, r.json["error"] == nil { return nil }
        return (r.json["error"] as? String)
            ?? String(format: NSLocalizedString("The host refused (%d).", comment: "sandbox drawer, fat client; %d = HTTP status"), r.status)
    }

    /// `GET /profiles/{id}?full=1`: the Profile document, bare or under "profile".
    nonisolated static func decodeProfile(_ json: [String: Any]) -> Profile? {
        let doc = (json["profile"] as? [String: Any]) ?? json
        guard let data = try? JSONSerialization.data(withJSONObject: doc) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601   // the host exports with ISO 8601 dates
        return try? dec.decode(Profile.self, from: data)
    }
}
