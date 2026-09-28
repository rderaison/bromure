import Foundation
import SandboxEngine

/// OCSF JSON export of every security event Bromure records — the same
/// shape NVIDIA OpenShell writes (`openshell-ocsf.YYYY-MM-DD.log`, OCSF
/// v1.8.0, one complete JSON object per line), so a SIEM pipeline built for
/// OpenShell sandboxes ingests Bromure workspaces unchanged.
///
/// Fed from `BACEventEmitter.emit` next to the Security Timeline — local and
/// independent of enrollment / private mode, like the timeline. Off by default:
///
///     defaults write io.bromure.agentic-coding ocsf.jsonExport -bool true
///     defaults write io.bromure.agentic-coding ocsf.schemaVersion 1.3.0   # Security Lake / Splunk / CrowdStrike
///
/// or from the Security Timeline window's export menu.
public final class OCSFExporter: @unchecked Sendable {
    public static let shared = OCSFExporter()

    public static let enabledKey = "ocsf.jsonExport"
    public static let schemaVersionKey = "ocsf.schemaVersion"
    public static let retentionDaysKey = "ocsf.retentionDays"
    public static let directoryKey = "ocsf.directory"

    public static let currentSchema = "1.8.0"
    /// Versions the export can be downgraded to (fields newer than the target
    /// are dropped, as OpenShell's `downgrade_event` does).
    public static let supportedSchemas = ["1.8.0", "1.3.0"]

    private let io = DispatchQueue(label: "io.bromure.ocsf-export", qos: .utility)
    private var lastPrunedDay: String?

    public var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    public var directory: URL {
        if let p = UserDefaults.standard.string(forKey: Self.directoryKey), !p.isEmpty {
            return URL(fileURLWithPath: (p as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BromureAC/ocsf", isDirectory: true)
    }

    /// Record one emitter event. Cheap no-op while the export is off.
    public func record(profileID: UUID, workspace: String?, eventType: String,
                       eventData: [String: AnyJSON], time: Date = Date()) {
        guard isEnabled else { return }
        let version = UserDefaults.standard.string(forKey: Self.schemaVersionKey) ?? Self.currentSchema
        guard var obj = Self.event(profileID: profileID, workspace: workspace, eventType: eventType,
                                   eventData: eventData, time: time) else { return }
        if version != Self.currentSchema { Self.downgrade(&obj, to: version) }
        guard let line = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return }
        let dir = directory
        let retention = max(1, UserDefaults.standard.object(forKey: Self.retentionDaysKey) as? Int ?? 7)
        io.async { [self] in
            let day = Self.dayString(time)
            let url = dir.appendingPathComponent("bromure-ocsf.\(day).jsonl")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil,
                                               attributes: [.posixPermissions: 0o600])
            }
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                h.write(line + Data("\n".utf8))
                try? h.close()
            }
            if lastPrunedDay != day {
                lastPrunedDay = day
                Self.prune(dir, keepDays: retention, today: time)
            }
        }
    }

    /// Wait for queued writes (tests).
    func flush() { io.sync {} }

    // MARK: - Mapping

    /// OCSF classes used, with their category.
    enum Class: Int {
        case fileSystem = 1001, processActivity = 1007, detectionFinding = 2004,
             networkActivity = 4001, httpActivity = 4002, apiActivity = 6003, base = 0
        var category: (Int, String) {
            switch self {
            case .fileSystem, .processActivity: return (1, "System Activity")
            case .detectionFinding:             return (2, "Findings")
            case .networkActivity, .httpActivity: return (4, "Network Activity")
            case .apiActivity:                  return (6, "Application Activity")
            case .base:                         return (0, "Uncategorized")
            }
        }
        var name: String {
            switch self {
            case .fileSystem: return "File System Activity"
            case .processActivity: return "Process Activity"
            case .detectionFinding: return "Detection Finding"
            case .networkActivity: return "Network Activity"
            case .httpActivity: return "HTTP Activity"
            case .apiActivity: return "API Activity"
            case .base: return "Base Event"
            }
        }
    }

    enum Severity: Int {
        case informational = 1, low = 2, medium = 3, high = 4
        var name: String { ["", "Informational", "Low", "Medium", "High"][rawValue] }
    }

    /// Map one Bromure event to an OCSF record (nil: nothing to export).
    static func event(profileID: UUID, workspace: String?, eventType: String,
                      eventData d: [String: AnyJSON], time: Date) -> [String: Any]? {
        func s(_ k: String) -> String? { if case .string(let v)? = d[k], !v.isEmpty { return v }; return nil }
        func i(_ k: String) -> Int? { if case .int(let v)? = d[k] { return v }; return nil }
        func b(_ k: String) -> Bool? { if case .bool(let v)? = d[k] { return v }; return nil }

        var cls = Class.apiActivity
        var activity = (99, "Other")
        var allowed: Bool? = nil           // nil: no action/disposition
        var severity = Severity.informational
        var message = eventType
        var extra: [String: Any] = [:]

        func endpoint(host: String?, ip: String? = nil, port: Int?) -> [String: Any] {
            var e: [String: Any] = [:]
            if let host { if EgressPolicy.parseIPv4Address(host) != nil { e["ip"] = host } else { e["domain"] = host } }
            if let ip { e["ip"] = ip }
            if let port { e["port"] = port }
            return e
        }
        func httpRequest(method: String?, host: String?, path: String?, port: Int?) -> [String: Any] {
            var url: [String: Any] = ["scheme": port == 80 ? "http" : "https"]
            if let host { url["hostname"] = host }
            if let path {
                let parts = path.split(separator: "?", maxSplits: 1)
                url["path"] = String(parts.first ?? "")
                if parts.count > 1 { url["query_string"] = String(parts[1]) }
            }
            if let port { url["port"] = port }
            var r: [String: Any] = ["url": url]
            if let method { r["http_method"] = method.uppercased() }
            return r
        }
        func httpActivity(_ method: String?) -> (Int, String) {
            switch method?.uppercased() {
            case "CONNECT": return (1, "Connect")
            case "DELETE":  return (2, "Delete")
            case "GET":     return (3, "Get")
            case "HEAD":    return (4, "Head")
            case "OPTIONS": return (5, "Options")
            case "POST":    return (6, "Post")
            case "PUT":     return (7, "Put")
            case "TRACE":   return (8, "Trace")
            default:        return (99, "Other")
            }
        }
        func finding(_ uid: String, _ title: String, desc: String? = nil) {
            cls = .detectionFinding
            activity = (1, "Create")
            var info: [String: Any] = ["uid": uid, "title": title]
            if let desc { info["desc"] = desc }
            extra["finding_info"] = info
        }

        switch eventType {
        case "egress.firewall":
            let action = (s("action") ?? "allow").lowercased()
            let audit = action == "audit"
            allowed = audit || action.contains("allow")
            severity = audit ? .low : (allowed! ? .informational : .medium)
            var rule: [String: Any] = ["type": s("rule").map { _ in "openshell" } ?? "bromure"]
            rule["name"] = s("rule") ?? (s("layer").map { "egress-\($0)" } ?? "egress")
            extra["firewall_rule"] = rule
            if s("layer") == "l7" {
                cls = .httpActivity
                activity = httpActivity(s("method"))
                extra["http_request"] = httpRequest(method: s("method"), host: s("host"), path: s("path"), port: i("port"))
                message = "\(s("method") ?? "") \(s("host") ?? "")\(s("path") ?? "") \(audit ? "audited" : (allowed! ? "allowed" : "denied"))"
            } else {
                cls = .networkActivity
                activity = (1, "Open")
                extra["dst_endpoint"] = endpoint(host: s("host"), ip: s("ip"), port: i("port"))
                message = "CONNECT \(allowed! ? "allowed" : "denied") \(s("host") ?? s("ip") ?? "?"):\(i("port") ?? 0)"
            }
            if let r = s("reason") { extra["status_detail"] = r }

        case "guardrails.block":
            cls = .httpActivity
            activity = httpActivity(s("method"))
            allowed = false
            severity = .medium
            extra["http_request"] = httpRequest(method: s("method"), host: s("host"), path: s("path"), port: nil)
            extra["firewall_rule"] = ["name": "guardrails", "type": "bromure"]
            extra["status_detail"] = s("reason") ?? "blocked by Bromure Guardrails"
            message = "Guardrails blocked \(s("method") ?? "") \(s("host") ?? "")\(s("path") ?? "")"

        case "supply_chain.fetch":
            cls = .httpActivity
            activity = (3, "Get")
            let outcome = (s("outcome") ?? "allowed").lowercased()
            allowed = !["blocked", "denied"].contains(outcome)
            severity = allowed! ? .informational : .medium
            extra["http_request"] = httpRequest(method: "GET", host: s("host") ?? s("registry"),
                                                path: s("path") ?? s("package"), port: nil)
            extra["firewall_rule"] = ["name": "supply-chain", "type": "bromure"]
            message = "Package \(s("package") ?? s("path") ?? "") \(outcome)"

        case "credential.exfiltration":
            finding("credential-exfiltration", "Credential sent to a host it wasn't issued for",
                    desc: "A workspace credential was seen heading to \(s("observed_host") ?? "?") (issued for \(s("declared_host") ?? "?")); the request was blocked.")
            allowed = false
            severity = .high
            extra["is_alert"] = true
            extra["attacks"] = [["technique": ["uid": "T1552", "name": "Unsecured Credentials"],
                                 "tactic": ["uid": "TA0006", "name": "Credential Access"]]]
            message = "Credential exfiltration blocked: \(s("observed_host") ?? "?")"

        case "credential.unmanaged":
            finding("credential-unmanaged", "Unmanaged credential in outbound request",
                    desc: "A request carried a credential Bromure did not inject for that destination.")
            allowed = b("blocked").map { !$0 } ?? false
            severity = .high
            extra["is_alert"] = true
            extra["attacks"] = [["technique": ["uid": "T1552", "name": "Unsecured Credentials"],
                                 "tactic": ["uid": "TA0006", "name": "Credential Access"]]]
            message = "Unmanaged credential (\(s("kind") ?? "secret")) to \(s("host") ?? "?")"

        case "credential.exfiltration_allowed":
            finding("credential-exfiltration-allowed", "Credential destination allowed for this session")
            activity = (2, "Update")
            allowed = true
            severity = .medium
            message = "User allowed a credential to reach \(s("observed_host") ?? "?")"

        case "tls.insecure_bypass", "tls.upstream_untrusted":
            let bypass = eventType == "tls.insecure_bypass"
            finding(eventType, bypass ? "Upstream certificate validation skipped on request"
                                      : "Untrusted upstream certificate")
            allowed = bypass
            severity = bypass ? .low : .medium
            message = "\(bypass ? "Insecure bypass" : "Untrusted certificate"): \(s("host") ?? "?")"

        case "watchdog.trip":
            let quarantine = s("action") == "quarantine"
            finding("agent-watchdog", "Agent session drifted from its normal behaviour",
                    desc: "Watchdog score \(i("score") ?? 0) within \(i("window_seconds") ?? 60)s")
            allowed = !quarantine
            severity = .high
            extra["is_alert"] = true
            message = quarantine ? "Agent quarantined by the watchdog" : "Agent watchdog alert"

        case "policy.proposal":
            finding("policy-proposal", "Network policy proposal",
                    desc: s("rule"))
            activity = (s("status") == "approved" ? 2 : 1, s("status") == "approved" ? "Update" : "Create")
            allowed = s("status").map { $0 != "rejected" }
            severity = .low
            message = "Policy proposal \(s("status") ?? "submitted"): \(s("host") ?? "")"

        case "command.run":
            cls = .processActivity
            activity = (1, "Launch")
            extra["process"] = ["cmd_line": s("command") ?? "", "name": s("tool") ?? "agent"]
            message = "Agent ran a command"

        case "file.read", "file.write":
            cls = .fileSystem
            activity = eventType == "file.read" ? (2, "Read") : (3, "Update")
            extra["file"] = ["path": s("path") ?? "", "name": (s("path") as NSString?)?.lastPathComponent ?? "",
                             "type_id": 1, "type": "Regular File"]
            message = "Agent \(eventType == "file.read" ? "read" : "wrote") \(s("path") ?? "?")"

        case "credential.token_swap", "credential.aws_sign", "credential.ssh_sign", "privacy.pii_swap",
             "tool.use", "llm.request", "agent.delegation", "vm.disk_reset":
            cls = .apiActivity
            activity = (99, "Other")
            var api: [String: Any] = ["operation": eventType]
            if let h = s("host") { api["service"] = ["name": h] }
            extra["api"] = api
            if let h = s("host") { extra["dst_endpoint"] = endpoint(host: h, port: nil) }
            message = eventType

        default:
            cls = .base
            activity = (99, "Other")
        }

        let (catUID, catName) = cls.category
        var obj: [String: Any] = [
            "class_uid": cls.rawValue, "class_name": cls.name,
            "category_uid": catUID, "category_name": catName,
            "activity_id": activity.0, "activity_name": activity.1,
            "type_uid": cls.rawValue * 100 + activity.0,
            "severity_id": severity.rawValue, "severity": severity.name,
            "time": Int((time.timeIntervalSince1970 * 1000).rounded()),
            "message": message,
            "metadata": [
                "uid": UUID().uuidString.lowercased(),
                "version": currentSchema,
                "product": ["name": "Bromure Agentic Coding", "vendor_name": "Bromure",
                            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"],
                "log_name": eventType,
            ] as [String: Any],
            "container": ["uid": profileID.uuidString.lowercased(), "name": workspace ?? ""]
                .filter { !($0.value.isEmpty) },
            "observation_point_id": 2,
        ]
        if let allowed {
            obj["action_id"] = allowed ? 1 : 2
            obj["action"] = allowed ? "Allowed" : "Denied"
            obj["disposition_id"] = allowed ? 1 : 2
            obj["disposition"] = allowed ? "Allowed" : "Blocked"
            obj["status_id"] = allowed ? 1 : 2
            obj["status"] = allowed ? "Success" : "Failure"
        }
        for (k, v) in extra { obj[k] = v }
        obj["unmapped"] = d.mapValues(\.jsonObject).merging(["bromure_event_type": eventType]) { a, _ in a }
        return obj
    }

    /// Drop fields a pre-1.8 consumer rejects (OpenShell `downgrade_event`).
    static func downgrade(_ obj: inout [String: Any], to version: String) {
        if version.compare("1.3.0", options: .numeric) != .orderedDescending {
            obj.removeValue(forKey: "container")
            obj.removeValue(forKey: "observation_point_id")
        }
        if var meta = obj["metadata"] as? [String: Any] {
            meta["version"] = version
            obj["metadata"] = meta
        }
    }

    private static func dayString(_ d: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    private static func prune(_ dir: URL, keepDays: Int, today: Date) {
        let cutoff = dayString(today.addingTimeInterval(-Double(keepDays - 1) * 86_400))
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for f in files where f.hasPrefix("bromure-ocsf.") && f.hasSuffix(".jsonl") {
            let day = String(f.dropFirst("bromure-ocsf.".count).dropLast(".jsonl".count))
            if day < cutoff { try? FileManager.default.removeItem(at: dir.appendingPathComponent(f)) }
        }
    }
}

extension AnyJSON {
    /// Foundation-JSON form (for JSONSerialization).
    var jsonObject: Any {
        switch self {
        case .string(let s): return s
        case .int(let i): return i
        case .double(let d): return d
        case .bool(let b): return b
        case .array(let a): return a.map(\.jsonObject)
        case .object(let o): return o.mapValues(\.jsonObject)
        case .null: return NSNull()
        }
    }
}
