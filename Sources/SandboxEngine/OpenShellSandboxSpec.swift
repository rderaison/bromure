import Foundation
import Yams

// MARK: - Guest sandbox spec (`/mnt/bromure-meta/openshell-sandbox.json`)
//
// OpenShell's `filesystem_policy` / `landlock` / `process` sections are
// enforced inside the workspace VM (Landlock, privilege drop, seccomp) by the
// guest's root launcher; the kernel sentry streams security events to the
// host. The host stages this spec before boot; the guest applies OpenShell's
// defaults for absent sections, exactly as OpenShell's sandbox does.

public struct OpenShellSandboxSpec: Equatable, Sendable {
    public static let fileName = "openshell-sandbox.json"
    public static let sentryVsockPort: UInt32 = 5841

    /// The three OpenShell sections, verbatim (JSON-compatible values);
    /// nil when the policy doesn't have one.
    public var filesystemPolicy: AnyJSONValue?
    public var landlock: AnyJSONValue?
    public var process: AnyJSONValue?
    /// The names of the policy's network rules. The guest adds OpenShell's
    /// baseline filesystem paths when there's at least one (as OpenShell
    /// does); an empty list is a definite "none".
    public var networkPolicyNames: [String]
    /// Guest paths of the workspace's project folders (`include_workdir`).
    public var workdirs: [String]
    public var strictSandbox: Bool
    /// Kernel sentry requirement: "off", "best_effort" or "hard".
    public var sentry: String

    /// Whether anything needs staging at all: the policy carries one of the
    /// sections, or the kernel sentry is on. Otherwise the guest behaves
    /// exactly as before.
    public var isActive: Bool {
        filesystemPolicy != nil || landlock != nil || process != nil || sentry != "off"
    }

    public init(policyYAML: String, workdirs: [String], strictSandbox: Bool, sentry: String) {
        let sections = Self.sections(of: policyYAML)
        filesystemPolicy = sections["filesystem_policy"]
        landlock = sections["landlock"]
        process = sections["process"]
        networkPolicyNames = Self.networkPolicyNames(of: policyYAML)
        self.workdirs = workdirs
        self.strictSandbox = strictSandbox
        self.sentry = ["best_effort", "hard"].contains(sentry) ? sentry : "off"
    }

    /// The sandbox sections of a policy document, for "did they change?"
    /// (they apply at VM start, unlike the network rules).
    public static func sectionsFingerprint(yaml: String) -> String {
        // (Not whether there are network rules, though that decides the
        // baseline filesystem paths: like OpenShell, the baseline is fixed at
        // start, and adding a first rule live — an approved advisor proposal,
        // say — must not restart the workspace.)
        let sections = Self.sections(of: yaml).mapValues(\.foundation)
        let data = (try? JSONSerialization.data(withJSONObject: sections, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// The top-level sandbox sections of a policy document, as JSON values.
    static func sections(of yaml: String) -> [String: AnyJSONValue] {
        guard let doc = (try? Yams.load(yaml: yaml)) as? [String: Any] else { return [:] }
        var out: [String: AnyJSONValue] = [:]
        for key in ["filesystem_policy", "landlock", "process"] {
            guard let v = doc[key], !(v is NSNull) else { continue }
            if let j = AnyJSONValue(v) { out[key] = j }
        }
        return out
    }

    static func networkPolicyNames(of yaml: String) -> [String] {
        guard let doc = (try? Yams.load(yaml: yaml)) as? [String: Any],
              let rules = doc["network_policies"] as? [String: Any] else { return [] }
        return rules.keys.sorted()
    }

    public func jsonData() -> Data {
        var obj: [String: Any] = [
            "version": 1,
            "workdirs": workdirs,
            "network_policies": networkPolicyNames,
            // `policy.local` (the advisor): the guest maps the name to this
            // address, which the switch diverts to the host's MiTM.
            "advisor": ["host": "policy.local", "address": EgressPolicy.advisorAddressString],
            "strict_sandbox": strictSandbox,
            "sentry": [
                "enabled": sentry != "off",
                "vsock_port": Int(Self.sentryVsockPort),
                "requirement": sentry == "hard" ? "hard" : "best_effort",
            ] as [String: Any],
        ]
        obj["filesystem_policy"] = filesystemPolicy?.foundation ?? NSNull()
        obj["landlock"] = landlock?.foundation ?? NSNull()
        obj["process"] = process?.foundation ?? NSNull()
        return (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .prettyPrinted])) ?? Data()
    }
}

/// A JSON value (the subset YAML sections turn into).
public indirect enum AnyJSONValue: Equatable, Sendable {
    case null, bool(Bool), int(Int), double(Double), string(String)
    case array([AnyJSONValue]), object([String: AnyJSONValue])

    init?(_ v: Any) {
        switch v {
        case is NSNull: self = .null
        case let b as Bool: self = .bool(b)
        case let i as Int: self = .int(i)
        case let d as Double: self = .double(d)
        case let s as String: self = .string(s)
        case let a as [Any]:
            var out: [AnyJSONValue] = []
            for e in a { guard let j = AnyJSONValue(e) else { return nil }; out.append(j) }
            self = .array(out)
        case let m as [String: Any]:
            var out: [String: AnyJSONValue] = [:]
            for (k, e) in m { guard let j = AnyJSONValue(e) else { return nil }; out[k] = j }
            self = .object(out)
        default:
            // Dates and other YAML scalars: keep their text.
            self = .string(String(describing: v))
        }
    }

    var foundation: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .int(let i): return i
        case .double(let d): return d
        case .string(let s): return s
        case .array(let a): return a.map(\.foundation)
        case .object(let m): return m.mapValues(\.foundation)
        }
    }
}
