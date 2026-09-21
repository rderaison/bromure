import Foundation

// MARK: - Automations MCP (per workspace)
//
// The automations MCP exposed to every agent in a workspace: list, read,
// create, edit, delete and run the workspace's OWN automations — the ones
// whose profile is this machine's. Nothing from any other workspace exists
// as far as the agent is concerned: every lookup filters by profile, a
// foreign id reads as "not found", and a created automation is always this
// workspace's, whatever the agent asks for. The transport is the board
// MCP's: a stdio shim in the guest (bromure-automations-mcp.py) pipes
// JSON-RPC lines over vsock (port 5833) to this handler, one bridge per
// machine — the profile is fixed by which VM the connection came from,
// never by anything the agent says.

@MainActor
final class AutomationMCPServer: MCPLineHandler {
    private let profileID: Profile.ID
    private let store: () -> ScheduledAutomationStore?
    private let profile: () -> Profile?
    private let save: (ScheduledAutomation) -> Void
    private let remove: (UUID) -> Void
    private let runNow: (UUID) -> Void

    init(profileID: Profile.ID,
         store: @escaping () -> ScheduledAutomationStore?,
         profile: @escaping () -> Profile?,
         save: @escaping (ScheduledAutomation) -> Void,
         remove: @escaping (UUID) -> Void,
         runNow: @escaping (UUID) -> Void) {
        self.profileID = profileID
        self.store = store
        self.profile = profile
        self.save = save
        self.remove = remove
        self.runNow = runNow
    }

    // MARK: JSON-RPC

    func handle(line: String, branch: String?) async -> String? {
        guard let data = line.data(using: .utf8),
              let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let id = msg["id"]
        let method = msg["method"] as? String ?? ""
        let params = msg["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            return respond(id: id, result: [
                "protocolVersion": "2025-03-26",
                "serverInfo": ["name": "bromure-automations", "version": "1.0.0"],
                "capabilities": ["tools": ["listChanged": false]],
                "instructions": Self.serverInstructions,
            ])
        case "notifications/initialized", "notifications/cancelled":
            return nil
        case "ping":
            return respond(id: id, result: [:])
        case "tools/list":
            return respond(id: id, result: ["tools": Self.toolDefinitions])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            return respond(id: id, result: callTool(name: name, args: args))
        default:
            guard id != nil else { return nil }
            return respondError(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    // MARK: Tools

    static let serverInstructions = """
    Tools for this workspace's Bromure automations — unattended agent runs \
    that fire on a schedule or on GitHub / Linear events, each in a fresh \
    git worktree of a repository in this machine. automation_list and \
    automation_get read them; automation_create, automation_update and \
    automation_delete change them; automation_run fires one now. Only this \
    workspace's automations exist here: ids from other workspaces are not \
    found, and anything you create belongs to this workspace.
    """

    private static let fieldProperties: [String: Any] = [
        "name": ["type": "string", "description": "What the automation is called."],
        "prompt": ["type": "string", "description": "The agent's opening message for each run."],
        "trigger": ["type": "string", "enum": ["schedule", "githubPullRequest", "githubIssue", "githubCommit", "linearIssue", "afterAutomation"],
                    "description": "What starts a run (default schedule)."],
        "frequency": ["type": "string", "enum": ["interval", "daily", "weekdays", "weekly"],
                      "description": "schedule trigger: how often (default weekdays)."],
        "intervalMinutes": ["type": "integer", "description": "frequency interval: minutes between runs (at least 5)."],
        "hour": ["type": "integer", "description": "daily / weekdays / weekly: hour of day, 0-23 (host clock)."],
        "minute": ["type": "integer", "description": "daily / weekdays / weekly: minute, 0-59."],
        "weekday": ["type": "integer", "description": "weekly: 1 = Sunday … 7 = Saturday."],
        "missedRunPolicy": ["type": "string", "enum": ["skip", "runOnWake"],
                            "description": "A fire time that passed while the Mac slept: skip it (default) or run when it wakes."],
        "tool": ["type": "string", "enum": ["claude", "codex", "grok", "kimi", "omp"],
                 "description": "The agent that runs (default: this workspace's main agent; must be configured on this machine)."],
        "repoPath": ["type": "string", "description": "Guest path of the repository to worktree off (default ~, the home)."],
        "githubRepo": ["type": "string", "description": "GitHub triggers: owner/repo to watch."],
        "linearTeam": ["type": "string", "description": "linearIssue: team key (e.g. ENG); empty = the whole workspace."],
        "assignmentFilter": ["type": "string", "enum": ["unassigned", "assignedToMe"],
                             "description": "linearIssue: which issues fire (default unassigned)."],
        "ignoreBacklog": ["type": "boolean", "description": "Event triggers: skip items that already exist when the watch starts (default true)."],
        "filters": ["type": "object", "description": "Event triggers: labels (array), titleContains, excludeDrafts, ignoreBots, baseBranch, commitBranch, commitSubfolder.",
                    "properties": [
                        "labels": ["type": "array", "items": ["type": "string"]],
                        "titleContains": ["type": "string"],
                        "excludeDrafts": ["type": "boolean"],
                        "ignoreBots": ["type": "boolean"],
                        "baseBranch": ["type": "string"],
                        "commitBranch": ["type": "string"],
                        "commitSubfolder": ["type": "string"],
                    ]],
        "chainedAutomationID": ["type": "string", "description": "afterAutomation: the id of THIS workspace's automation whose finished run fires this one."],
        "enabled": ["type": "boolean", "description": "Default true."],
        "closeWhenDone": ["type": "boolean", "description": "Close the run's tab once the agent reports done (default true)."],
        "startWorkspaceIfNeeded": ["type": "boolean", "description": "Boot the machine for a run when it's off (default true)."],
        "cloneWorkspaceFirst": ["type": "boolean", "description": "Run in a disposable copy of the machine (default false)."],
    ]

    static let toolDefinitions: [[String: Any]] = [
        [
            "name": "automation_list",
            "description": "This workspace's automations, with each one's schedule and last run.",
            "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
        ],
        [
            "name": "automation_get",
            "description": "One automation of this workspace in full, with its last ten runs.",
            "inputSchema": ["type": "object",
                            "properties": ["id": ["type": "string"]],
                            "required": ["id"]],
        ],
        [
            "name": "automation_create",
            "description": "Create an automation in this workspace. name and prompt are required; everything else has a sensible default (a weekdays 09:00 schedule running the workspace's main agent in ~).",
            "inputSchema": ["type": "object", "properties": fieldProperties, "required": ["name", "prompt"]],
        ],
        [
            "name": "automation_update",
            "description": "Change fields of one of this workspace's automations. Only the fields given change.",
            "inputSchema": ["type": "object",
                            "properties": fieldProperties.merging(["id": ["type": "string"]]) { $1 },
                            "required": ["id"]],
        ],
        [
            "name": "automation_delete",
            "description": "Delete one of this workspace's automations (its run history goes with it).",
            "inputSchema": ["type": "object",
                            "properties": ["id": ["type": "string"]],
                            "required": ["id"]],
        ],
        [
            "name": "automation_run",
            "description": "Fire one of this workspace's automations now, as if its trigger had just happened.",
            "inputSchema": ["type": "object",
                            "properties": ["id": ["type": "string"]],
                            "required": ["id"]],
        ],
    ]

    // MARK: Scope

    /// Only this workspace's. A foreign id is simply not found.
    private func mine(_ raw: Any?) -> ScheduledAutomation? {
        guard let s = raw as? String, let id = UUID(uuidString: s.trimmingCharacters(in: .whitespaces)),
              let a = store()?.automation(id), a.profileID == profileID else { return nil }
        return a
    }

    private var ownAutomations: [ScheduledAutomation] {
        (store()?.automations ?? []).filter { $0.profileID == profileID }
            .sorted { $0.createdAt < $1.createdAt }
    }

    private func callTool(name: String, args: [String: Any]) -> [String: Any] {
        guard let store = store() else { return errorResult("automations unavailable") }
        switch name {
        case "automation_list":
            let list = ownAutomations.map { describe($0, store: store, runs: 1) }
            return textResult(jsonString(["automations": list, "count": list.count]))
        case "automation_get":
            guard let a = mine(args["id"]) else { return errorResult("no automation with that id in this workspace") }
            return textResult(jsonString(describe(a, store: store, runs: 10)))
        case "automation_create":
            guard let profile = profile() else { return errorResult("workspace unavailable") }
            var a = ScheduledAutomation(profileID: profileID, tool: profile.tool)
            if let err = apply(args, to: &a, profile: profile, creating: true) { return errorResult(err) }
            save(a)
            BACDebug.log("automations", "“\(a.name)”: created via MCP in \(profile.name)")
            return textResult("Created.\n" + jsonString(describe(a, store: store, runs: 0)))
        case "automation_update":
            guard var a = mine(args["id"]) else { return errorResult("no automation with that id in this workspace") }
            guard let profile = profile() else { return errorResult("workspace unavailable") }
            if let err = apply(args, to: &a, profile: profile, creating: false) { return errorResult(err) }
            save(a)
            BACDebug.log("automations", "“\(a.name)”: updated via MCP")
            return textResult("Updated.\n" + jsonString(describe(a, store: store, runs: 0)))
        case "automation_delete":
            guard let a = mine(args["id"]) else { return errorResult("no automation with that id in this workspace") }
            remove(a.id)
            BACDebug.log("automations", "“\(a.name)”: deleted via MCP")
            return textResult("Deleted “\(a.name)”.")
        case "automation_run":
            guard let a = mine(args["id"]) else { return errorResult("no automation with that id in this workspace") }
            runNow(a.id)
            BACDebug.log("automations", "“\(a.name)”: run now via MCP")
            return textResult("Firing “\(a.name)” now. automation_get shows the run once it's recorded.")
        default:
            return errorResult("Unknown tool: \(name)")
        }
    }

    /// Apply the tool's fields onto `a`, validating as the editor would.
    /// Returns an error message, or nil when everything landed.
    private func apply(_ args: [String: Any], to a: inout ScheduledAutomation,
                       profile: Profile, creating: Bool) -> String? {
        if let v = args["name"] as? String {
            let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return "name can't be empty" }
            a.name = t
        }
        if let v = args["prompt"] as? String {
            let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return "prompt can't be empty" }
            a.prompt = t
        }
        if let v = args["trigger"] as? String {
            guard let t = ScheduledAutomation.TriggerKind(rawValue: v) else {
                return "trigger must be one of schedule, githubPullRequest, githubIssue, githubCommit, linearIssue, afterAutomation"
            }
            a.trigger = t
        }
        if let v = args["frequency"] as? String {
            guard let f = ScheduledAutomation.Frequency(rawValue: v) else {
                return "frequency must be one of interval, daily, weekdays, weekly"
            }
            a.frequency = f
        }
        if let v = args["intervalMinutes"] as? Int {
            guard v >= 5 else { return "intervalMinutes must be at least 5" }
            a.intervalMinutes = v
        }
        if let v = args["hour"] as? Int {
            guard (0...23).contains(v) else { return "hour must be 0-23" }
            a.hour = v
        }
        if let v = args["minute"] as? Int {
            guard (0...59).contains(v) else { return "minute must be 0-59" }
            a.minute = v
        }
        if let v = args["weekday"] as? Int {
            guard (1...7).contains(v) else { return "weekday must be 1 (Sunday) to 7 (Saturday)" }
            a.weekday = v
        }
        if let v = args["missedRunPolicy"] as? String {
            guard let p = ScheduledAutomation.MissedRunPolicy(rawValue: v) else {
                return "missedRunPolicy must be skip or runOnWake"
            }
            a.missedRunPolicy = p
        }
        if let v = args["tool"] as? String {
            guard let t = Profile.Tool(rawValue: v) else { return "unknown tool \(v)" }
            let configured = profile.allToolSpecs.map(\.tool)
            guard configured.contains(t) else {
                return "\(t.displayName) isn't set up on this machine (available: "
                    + configured.map(\.rawValue).joined(separator: ", ") + ")"
            }
            a.tool = t
        }
        if let v = args["repoPath"] as? String {
            let t = v.trimmingCharacters(in: .whitespaces)
            a.repoPath = t.isEmpty ? "~" : t
        }
        if let v = args["githubRepo"] as? String { a.githubRepo = v.trimmingCharacters(in: .whitespaces) }
        if let v = args["linearTeam"] as? String { a.linearTeam = v.trimmingCharacters(in: .whitespaces) }
        if let v = args["assignmentFilter"] as? String {
            guard let f = ScheduledAutomation.AssignmentFilter(rawValue: v) else {
                return "assignmentFilter must be unassigned or assignedToMe"
            }
            a.assignmentFilter = f
        }
        if let v = args["ignoreBacklog"] as? Bool { a.ignoreBacklog = v }
        if let f = args["filters"] as? [String: Any] {
            if let v = f["labels"] as? [String] { a.filters.labels = v }
            if let v = f["titleContains"] as? String { a.filters.titleContains = v }
            if let v = f["excludeDrafts"] as? Bool { a.filters.excludeDrafts = v }
            if let v = f["ignoreBots"] as? Bool { a.filters.ignoreBots = v }
            if let v = f["baseBranch"] as? String { a.filters.baseBranch = v }
            if let v = f["commitBranch"] as? String { a.filters.commitBranch = v }
            if let v = f["commitSubfolder"] as? String { a.filters.commitSubfolder = v }
        }
        if let v = args["chainedAutomationID"] as? String {
            // Chains stay inside the workspace: the upstream must be ours.
            guard let up = mine(v), up.id != a.id else {
                return "chainedAutomationID must be another automation of this workspace"
            }
            a.chainedAutomationID = up.id
        }
        if let v = args["enabled"] as? Bool { a.enabled = v }
        if let v = args["closeWhenDone"] as? Bool { a.closeWhenDone = v }
        if let v = args["startWorkspaceIfNeeded"] as? Bool { a.startWorkspaceIfNeeded = v }
        if let v = args["cloneWorkspaceFirst"] as? Bool { a.cloneWorkspaceFirst = v }

        // Cross-field checks, on the final shape.
        if creating {
            guard !a.name.isEmpty else { return "name is required" }
            guard !a.prompt.isEmpty else { return "prompt is required" }
        }
        if a.trigger.isGitHub, a.githubRepo.isEmpty {
            return "githubRepo (owner/repo) is required for a \(a.trigger.rawValue) trigger"
        }
        if a.trigger == .afterAutomation, a.chainedAutomationID == nil {
            return "chainedAutomationID is required for an afterAutomation trigger"
        }
        // Whatever was asked, the automation is this workspace's.
        a.profileID = profileID
        return nil
    }

    // MARK: Describing

    private func describe(_ a: ScheduledAutomation, store: ScheduledAutomationStore,
                          runs limit: Int) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        var d: [String: Any] = [
            "id": a.id.uuidString,
            "name": a.name,
            "enabled": a.enabled,
            "trigger": a.trigger.rawValue,
            "when": schedule(a),
            "tool": a.tool.rawValue,
            "prompt": a.prompt,
            "repoPath": a.repoPath,
            "closeWhenDone": a.closeWhenDone,
            "startWorkspaceIfNeeded": a.startWorkspaceIfNeeded,
            "cloneWorkspaceFirst": a.cloneWorkspaceFirst,
            "missedRunPolicy": a.missedRunPolicy.rawValue,
            "createdAt": iso.string(from: a.createdAt),
        ]
        if a.trigger == .schedule {
            d["frequency"] = a.frequency.rawValue
            switch a.frequency {
            case .interval: d["intervalMinutes"] = a.intervalMinutes
            case .weekly:   d["weekday"] = a.weekday; d["hour"] = a.hour; d["minute"] = a.minute
            default:        d["hour"] = a.hour; d["minute"] = a.minute
            }
        }
        if a.trigger.isGitHub { d["githubRepo"] = a.githubRepo }
        if a.trigger == .linearIssue {
            d["linearTeam"] = a.linearTeam
            d["assignmentFilter"] = a.assignmentFilter.rawValue
        }
        if a.trigger != .schedule, a.trigger != .afterAutomation {
            d["ignoreBacklog"] = a.ignoreBacklog
            var f: [String: Any] = [
                "excludeDrafts": a.filters.excludeDrafts, "ignoreBots": a.filters.ignoreBots,
            ]
            if !a.filters.labels.isEmpty { f["labels"] = a.filters.labels }
            if !a.filters.titleContains.isEmpty { f["titleContains"] = a.filters.titleContains }
            if !a.filters.baseBranch.isEmpty { f["baseBranch"] = a.filters.baseBranch }
            if !a.filters.commitBranch.isEmpty { f["commitBranch"] = a.filters.commitBranch }
            if !a.filters.commitSubfolder.isEmpty { f["commitSubfolder"] = a.filters.commitSubfolder }
            d["filters"] = f
        }
        if let c = a.chainedAutomationID { d["chainedAutomationID"] = c.uuidString }
        if limit > 0 {
            let recent = store.runs.filter { $0.automationID == a.id }
                .sorted { $0.firedAt > $1.firedAt }.prefix(limit)
            let list: [[String: Any]] = recent.map { r in
                var o: [String: Any] = ["firedAt": iso.string(from: r.firedAt),
                                        "outcome": r.outcome.rawValue, "detail": r.detail]
                if let b = r.branchSlug { o["branch"] = "wt/" + b }
                return o
            }
            d[limit == 1 ? "lastRun" : "runs"] = limit == 1 ? (list.first ?? [:]) : list
        }
        return d
    }

    /// "weekdays at 09:00", "every 30 min", "on new pull requests in o/r"…
    private func schedule(_ a: ScheduledAutomation) -> String {
        let hm = String(format: "%02d:%02d", a.hour, a.minute)
        switch a.trigger {
        case .schedule:
            switch a.frequency {
            case .interval: return "every \(a.intervalMinutes) min"
            case .daily:    return "daily at \(hm)"
            case .weekdays: return "weekdays at \(hm)"
            case .weekly:
                let names = ["", "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
                let day = (1...7).contains(a.weekday) ? names[a.weekday] : "day \(a.weekday)"
                return "\(day)s at \(hm)"
            }
        case .githubPullRequest: return "on new pull requests in \(a.githubRepo)"
        case .githubIssue:       return "on new issues in \(a.githubRepo)"
        case .githubCommit:      return "on new commits in \(a.githubRepo)"
        case .linearIssue:       return "on new Linear issues" + (a.linearTeam.isEmpty ? "" : " in \(a.linearTeam)")
        case .afterAutomation:
            let up = a.chainedAutomationID.flatMap { store()?.automation($0) }?.name ?? "another automation"
            return "after “\(up)” finishes"
        }
    }

    // MARK: JSON helpers (board MCP conventions)

    private func textResult(_ s: String) -> [String: Any] {
        ["content": [["type": "text", "text": s]]]
    }

    private func errorResult(_ msg: String) -> [String: Any] {
        ["content": [["type": "text", "text": "Error: \(msg)"]], "isError": true]
    }

    private func jsonString(_ v: Any) -> String {
        guard JSONSerialization.isValidJSONObject(v),
              let data = try? JSONSerialization.data(withJSONObject: v, options: [.sortedKeys, .prettyPrinted]),
              let s = String(data: data, encoding: .utf8) else { return "\(v)" }
        return s
    }

    private func respond(id: Any?, result: [String: Any]) -> String? {
        var msg: [String: Any] = ["jsonrpc": "2.0", "result": result]
        if let id { msg["id"] = id } else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: msg),
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    private func respondError(id: Any?, code: Int, message: String) -> String? {
        var msg: [String: Any] = ["jsonrpc": "2.0", "error": ["code": code, "message": message]]
        if let id { msg["id"] = id } else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: msg),
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }
}
