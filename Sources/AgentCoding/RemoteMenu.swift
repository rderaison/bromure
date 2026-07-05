import ArgumentParser
import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// `bromure-ac __remote-menu` — the curses-style minishell that every remote
/// SSH login is forced into (`ForceCommand` in the generated sshd_config).
/// Hidden from `--help`: it's an internal entry point, not a user command.
///
/// It exposes, as menus, the same operations as the `bromure-ac` CLI, and lets
/// you attach to a running session's tmux. It talks to the running app over the
/// owner-only control socket (the same transport the CLI uses).
struct RemoteMenu: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__remote-menu",
        abstract: "Interactive remote menu (internal; used as the SSH ForceCommand).",
        shouldDisplay: false)

    func run() throws {
        guard isatty(STDIN_FILENO) != 0 else {
            print("The bromure-ac remote menu needs a terminal. Reconnect with: ssh -t …")
            return
        }
        RemoteMenuApp().run()
    }
}

final class RemoteMenuApp {
    private let tui = TUI()
    private let client = ControlClient()

    /// The magic-keychord trigger byte (default Ctrl-] = 0x1D). Caught host-side
    /// by `InteractiveExec` while attached, so it never reaches the guest tmux.
    /// Configurable — a knob most users never touch — via the `remote/overlay-key`
    /// file (e.g. "C-]", "C-o", "0x1d") or the `BROMURE_OVERLAY_KEY` env var.
    private lazy var overlayTrigger: UInt8 = Self.resolveOverlayTrigger()

    private static func resolveOverlayTrigger() -> UInt8 {
        let fileURL = ProfileStore().controlSocketURL.deletingLastPathComponent()
            .appendingPathComponent("remote", isDirectory: true)
            .appendingPathComponent("overlay-key")
        if let raw = try? String(contentsOf: fileURL, encoding: .utf8),
           let b = Self.parseChordByte(raw) { return b }
        if let env = ProcessInfo.processInfo.environment["BROMURE_OVERLAY_KEY"],
           let b = Self.parseChordByte(env) { return b }
        return 0x1D   // Ctrl-]
    }

    /// Parse a chord spec into its control byte: "C-]"/"^]"/"]" (control forms),
    /// "0x1d" (hex), or "29" (decimal). Returns nil if unrecognized.
    static func parseChordByte(_ raw: String) -> UInt8? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.lowercased().hasPrefix("0x"), let v = UInt8(s.dropFirst(2), radix: 16) { return v }
        if let v = UInt8(s) { return v }                       // plain decimal byte
        let body: Substring
        if s.count >= 2, s.prefix(2).lowercased() == "c-" { body = s.dropFirst(2) }
        else if s.hasPrefix("^") { body = s.dropFirst(1) }
        else { body = Substring(s) }
        guard body.count == 1, let a = body.first?.uppercased().first?.asciiValue else { return nil }
        return a & 0x1f                                        // Ctrl- masks the top bits
    }

    /// Human label for a control byte, e.g. 0x1D → "Ctrl-]".
    static func chordLabel(_ b: UInt8) -> String {
        // Control byte → the letter it masks from (0x1D ← ']' 0x5D).
        let letter = Character(UnicodeScalar(b | 0x40))
        return "Ctrl-\(letter)"
    }

    func run() {
        // Make sure the app/agent is up so the control socket answers.
        try? client.ensureAgentRunning()
        tui.begin()
        defer { tui.end() }
        topMenu()
    }

    // MARK: - Top level

    private func topMenu() {
        let items = ["Workspaces", "Models", "Trace", "Exit (disconnect)"]
        while true {
            guard let sel = tui.menu(title: "bromure-ac · remote",
                                     items: items,
                                     footer: "↑/↓ move · Enter select · Exit to disconnect") else {
                return                         // Esc/q at top level = disconnect
            }
            switch sel {
            case 0: workspacesMenu()
            case 1: modelsMenu()
            case 2: traceMenu()
            default: return                    // Exit
            }
        }
    }

    // MARK: - Workspaces (unified — live + off, mirroring the app's window)

    /// One list of every workspace with its live state; selecting one offers the
    /// state-appropriate actions (start an off one, attach/kill a running one).
    private func workspacesMenu() {
        while true {
            let ws = fetchProfiles()
            // "New workspace" first, then the live list, then the raw table.
            var labels = ["＋ New workspace…"]
            labels.append(contentsOf: ws.map { workspaceLabel($0) })
            labels.append("List (raw table)")
            let newIndex = 0
            let rawIndex = labels.count - 1
            guard let sel = tui.menu(title: "Workspaces", items: labels,
                                     footer: "Enter: open · q: back") else { return }
            if sel == newIndex { newWorkspaceForm(); continue }
            if sel == rawIndex { showOutput("workspaces ls", ["workspaces", "ls"]); continue }
            let wsIndex = sel - 1
            if wsIndex >= 0, wsIndex < ws.count { workspaceActions(ws[wsIndex]) }
        }
    }

    // MARK: - Create (single-screen form — the whole config on one page)

    /// One screen showing every common field at once (edit any in place), a
    /// "Full settings…" door into the same pane forms Configure uses, then
    /// Create. Unspecified fields inherit the app's Preferences template
    /// server-side, so the draft can stay sparse.
    private func newWorkspaceForm() {
        var doc: [String: Any] = ["tool": "claude", "authMode": "token", "color": "blue"]
        var generateSSH = false
        while true {
            let name = (doc["name"] as? String) ?? ""
            let folders = (doc["folderPaths"] as? [String]) ?? []
            let apiSet = !((doc["apiKey"] as? String) ?? "").isEmpty
            let mem = (doc["memoryGB"] as? Int).map { "\($0) GB" } ?? "default"

            // A single form: field rows first, then actions.
            let rows = [
                "Name         \(name.isEmpty ? "— (required)" : name)",
                "Tool         \(doc["tool"] as? String ?? "claude")",
                "Auth         \(doc["authMode"] as? String ?? "token")",
                "API key      \(apiSet ? "•••• (set)" : "—")",
                "Memory       \(mem)",
                "Color        \(doc["color"] as? String ?? "blue")",
                "Folders      \(folders.isEmpty ? "—" : "\(folders.count) shared")",
                "Generate SSH \(generateSSH ? "yes" : "no")",
                "Full settings…  (Fusion, Guardrails, MCP, …)",
                "───────────────",
                "✔ Create workspace",
                "Cancel",
            ]
            guard let sel = tui.menu(title: "New workspace", items: rows,
                                     footer: "Enter edit · q cancel") else { return }
            switch sel {
            case 0: _ = editField(&doc, key: "name", label: "Workspace name", kind: .text(secret: false))
            case 1: _ = editField(&doc, key: "tool", label: "Primary tool",
                                  kind: .pick(["claude", "codex", "grok"]))
            case 2:
                _ = editField(&doc, key: "authMode", label: "Auth mode",
                              kind: .pick(["token", "subscription", "bedrock", "local"]))
                if (doc["authMode"] as? String) == "subscription" {
                    tui.pager(title: "Subscription auth",
                              body: "Subscription mode signs in inside the VM.\n\n"
                                  + "After the workspace boots, attach and run "
                                  + "`\(doc["tool"] as? String ?? "claude") login` in the "
                                  + "session's tmux to complete sign-in.")
                }
            case 3: _ = editField(&doc, key: "apiKey", label: "API key (for token auth)",
                                  kind: .text(secret: true))
            case 4: _ = editField(&doc, key: "memoryGB", label: "VM RAM (GB, blank = default)", kind: .int)
            case 5: _ = editField(&doc, key: "color", label: "Accent color",
                                  kind: .pick(["blue", "red", "green", "orange", "purple", "pink", "teal", "gray"]))
            case 6: _ = editFolders(&doc)
            case 7: generateSSH.toggle()
            case 8: runConfigPanes(&doc, name: name.isEmpty ? "new workspace" : name)
            case 10: // Create
                guard !name.trimmingCharacters(in: .whitespaces).isEmpty else {
                    tui.toast("A name is required"); continue
                }
                if generateSSH { doc["generateSSH"] = true }
                let resp = try? client.request("POST", "/profiles", body: doc)
                guard let resp, resp.status == 201, (resp.json["ok"] as? Bool) == true else {
                    tui.pager(title: "Create failed",
                              body: (resp?.json["error"] as? String) ?? "The agent refused the request.")
                    continue
                }
                if let pub = resp.json["sshPublicKey"] as? String, !pub.isEmpty {
                    tui.pager(title: "SSH public key", body: "Add this to your Git host:\n\n\(pub)")
                }
                let sid = resp.json["shortId"] as? String ?? ""
                if tui.confirm("Created \(name)\(sid.isEmpty ? "" : " (\(sid))"). Start it now?",
                               defaultYes: true),
                   let id = resp.json["id"] as? String {
                    startWorkspace(id: id, name: name)
                }
                return
            case 11: return   // Cancel
            default: break     // separator row
            }
        }
    }

    private func workspaceActions(_ ws: [String: Any]) {
        let id = (ws["id"] as? String) ?? (ws["shortId"] as? String) ?? ""
        let name = ws["name"] as? String ?? id
        let state = ws["state"] as? String ?? "off"
        let live = (state == "running" || state == "booting")
        while true {
            if live {
                // Pull live state each loop so the Fusion label reflects the last
                // toggle. Fusion only appears when the workspace allows it.
                let vm = fetchVM(id)
                let fusionConfigurable = vm?["fusionConfigurable"] as? Bool ?? false
                let fusionEngaged = vm?["fusionEngaged"] as? Bool ?? false
                let routing = vm?["routing"] as? String ?? "cloud"
                var labels = ["Attach", "New tab", "Describe", "Configure…"]
                var actions: [() -> Bool] = [
                    { self.attachMenu(vmID: id, name: name); return false },
                    { // create the tab (it becomes tmux's active window), then attach to it
                      if self.postNewTab(vmID: id) { self.attach(vmID: id, name: name) }
                      else { self.tui.toast("Couldn't open a tab") }
                      return false },
                    { self.showOutput("describe \(name)", ["workspaces", "describe", id]); return false },
                    { self.configureWorkspace(id: id, name: name); return false },
                ]
                if fusionConfigurable {
                    labels.append("Fusion: \(fusionEngaged ? "on ✓" : "off")")
                    actions.append { self.toggleFusion(id: id, name: name, currentlyOn: fusionEngaged); return false }
                }
                labels.append("Routing: \(routing)")
                actions.append { self.chooseRouting(id: id, name: name, current: routing); return false }
                labels.append("Worktrees…")
                actions.append { self.worktreeMenu(vmID: id, name: name); return false }
                labels.append("Reboot…")
                actions.append { self.rebootWorkspace(id: id, name: name); return false }
                labels.append("Suspend")
                actions.append {
                    guard self.tui.confirm("Suspend \(name)? (saves RAM, resumes fast)") else { return false }
                    self.showOutput("suspend \(name)", ["vm", "kill", id, "--suspend"]); return true
                }
                labels.append("Kill")
                actions.append {
                    guard self.tui.confirm("Kill \(name)?") else { return false }
                    self.showOutput("kill \(name)", ["vm", "kill", id]); return true
                }
                labels.append("Back")
                guard let sel = tui.menu(title: "Workspace: \(name)  ·  \(state)",
                                         items: labels, footer: "Enter select · q back",
                                         header: vmDashboardLines(vm)) else { return }
                if sel >= 0, sel < actions.count {
                    if actions[sel]() { return }
                } else { return }              // Back
            } else {
                let items = ["Start", "Describe", "Configure…", "Delete", "Back"]
                guard let sel = tui.menu(title: "Workspace: \(name)  ·  \(state)",
                                         items: items, footer: "Enter select · q back") else { return }
                switch sel {
                case 0: startWorkspace(id: id, name: name); return
                case 1: showOutput("describe \(name)", ["workspaces", "describe", id])
                case 2: configureWorkspace(id: id, name: name)
                case 3:
                    guard tui.confirm("Delete \(name) and ALL its data (disk + home)?") else { break }
                    showOutput("rm \(name)", ["workspaces", "rm", id, "--force"]); return
                default: return
                }
            }
        }
    }

    // MARK: - Configure (native forms for every pane + a raw-JSON escape hatch)

    /// A single editable field, bound to a JSON key in the profile document.
    private enum FieldKind {
        case text(secret: Bool)
        case int
        case double
        case bool
        case pick([String])            // enum raw values (display == stored value)
        case pickLabeled([(label: String, value: String)])  // GUI-friendly label → stored raw value
        case modelPick                 // dropdown of installed local models (stores the id; "None" clears)
    }

    /// Full-fidelity configuration, mirroring the app's editor panes. Fetches
    /// the whole profile document once (secrets blanked), edits it in memory
    /// across the panes, and PUTs on save. Collection-heavy panes (Credentials,
    /// MCP) plus a catch-all raw-JSON hatch guarantee every field is reachable.
    private func configureWorkspace(id: String, name: String) {
        guard let cur = try? client.request(
            "GET", "/profiles/\(ControlClient.encodeSegment(id))?full=1"), cur.status == 200 else {
            tui.pager(title: "Configure \(name)", body: "Couldn't fetch the configuration.")
            return
        }
        var doc = cur.json
        var dirty = false

        while true {
            var labels = Self.configPaneNames
            labels.append("Generate new SSH key")
            labels.append(dirty ? "＊ Save changes" : "Save changes")
            labels.append("Back")
            let sshIndex = Self.configPaneNames.count
            let saveIndex = sshIndex + 1
            let backIndex = sshIndex + 2

            guard let sel = tui.menu(title: "Configure: \(name)\(dirty ? "  ·  unsaved" : "")",
                                     items: labels, footer: "Enter · q back") else {
                if dirty, !tui.confirm("Discard unsaved changes to \(name)?") { continue }
                return
            }
            if sel == backIndex {
                if dirty, !tui.confirm("Discard unsaved changes to \(name)?") { continue }
                return
            } else if sel == saveIndex {
                if putProfileDoc(id: id, name: name, doc: doc) { dirty = false }
            } else if sel == sshIndex {
                // Generating a key saves the whole document too, so it clears the
                // dirty flag on success.
                if generateWorkspaceSSH(id: id, name: name, doc: doc) { dirty = false }
            } else if sel >= 0, sel < Self.configPaneNames.count {
                if dispatchConfigPane(Self.configPaneNames[sel], &doc, workspace: name) { dirty = true }
            }
        }
    }

    /// The pane list shared by Configure (an existing workspace) and the new
    /// workspace form's "Full settings…". Credentials/MCP route to the raw-JSON
    /// hatch so every nested field stays reachable.
    // Same panes, same names, same order as the GUI editor's `EditorCategory`
    // (Automation is Preferences-only, so it's not a per-workspace pane).
    private static let configPaneNames = [
        "General", "Agents", "Local Models", "Fusion", "Folders", "Credentials",
        "Environment", "MCP", "Tracing", "Guardrails", "Supply Chain",
        "Prompt Injection", "Appearance", "Resources",
    ]

    /// Dispatch one pane by name onto `doc`. Returns whether it changed anything.
    private func dispatchConfigPane(_ pane: String, _ doc: inout [String: Any],
                                    workspace: String) -> Bool {
        switch pane {
        case "General":          return editGeneral(&doc)
        case "Agents":           return editAgents(&doc)
        case "Local Models":     return editLocalModels(&doc)
        case "Fusion":           return editFusion(&doc)
        case "Folders":          return editFolders(&doc)
        case "Credentials":      return editCredentials(&doc)
        case "Environment":      return editEnvironment(&doc)
        case "MCP":              return editMCP(&doc)
        case "Tracing":          return editTracing(&doc)
        case "Guardrails":       return editGuardrails(&doc)
        case "Supply Chain":     return editSupplyChain(&doc)
        case "Prompt Injection": return editPromptInjection(&doc)
        case "Appearance":       return editAppearance(&doc)
        case "Resources":        return editResources(&doc)
        default: return false
        }
    }

    /// Catalog models for the model dropdowns — the same source as the GUI's
    /// Local Models pane (`CatalogStore`), read from disk so it works in this
    /// out-of-app `__remote-menu` process too. EVERY catalog entry is listed;
    /// uninstalled ones can be downloaded in place (the GUI's ⬇ rows).
    private func catalogModels() -> [(id: String, label: String, installed: Bool, sizeGB: Double)] {
        CatalogStore.shared.effective().models.map {
            (id: $0.id,
             label: $0.name.isEmpty ? $0.id : $0.name,
             installed: CatalogStore.shared.isInstalled(repo: $0.repo),
             sizeGB: $0.downloadGB)
        }
    }

    /// Show the full pane list and edit `doc` in place until Back (used by the
    /// new workspace form's "Full settings…"). No save here — the caller PUTs
    /// or POSTs the whole document afterwards.
    private func runConfigPanes(_ doc: inout [String: Any], name: String) {
        while true {
            var labels = Self.configPaneNames
            labels.append("Back")
            guard let sel = tui.menu(title: "Settings: \(name)", items: labels,
                                     footer: "Enter · q back") else { return }
            if sel >= Self.configPaneNames.count { return }
            _ = dispatchConfigPane(Self.configPaneNames[sel], &doc, workspace: name)
        }
    }

    /// Generate a fresh SSH key host-side (the private seed never enters the VM)
    /// and show the public key for pasting into a Git host. PUTs the current
    /// document too, so it returns true (saved) on success.
    private func generateWorkspaceSSH(id: String, name: String, doc: [String: Any]) -> Bool {
        guard tui.confirm("Generate a new SSH key for \(name)? (replaces any existing generated key)")
        else { return false }
        var body = doc
        body["generateSSH"] = true
        guard let resp = try? client.request(
            "PUT", "/profiles/\(ControlClient.encodeSegment(id))", body: body),
            resp.status == 200, (resp.json["ok"] as? Bool) == true else {
            tui.pager(title: "SSH · \(name)", body: "Couldn't generate a key.")
            return false
        }
        let pub = resp.json["sshPublicKey"] as? String ?? ""
        tui.pager(title: "SSH public key · \(name)",
                  body: pub.isEmpty ? "Generated." : "Add this to your Git host:\n\n\(pub)")
        return true
    }

    /// PUT the edited document; returns true on success.
    private func putProfileDoc(id: String, name: String, doc: [String: Any]) -> Bool {
        guard let resp = try? client.request(
            "PUT", "/profiles/\(ControlClient.encodeSegment(id))", body: doc) else {
            tui.pager(title: "Save \(name)", body: "Couldn't reach the agent."); return false
        }
        if resp.status == 200, (resp.json["ok"] as? Bool) == true {
            tui.toast("Saved \(name)")
            return true
        }
        tui.pager(title: "Save \(name)",
                  body: (resp.json["error"] as? String) ?? "Save failed (HTTP \(resp.status)).")
        return false
    }

    // MARK: Generic field-form engine (operates on any JSON sub-dictionary)

    /// Fallback values for fields the control API OMITS: Profile encodes
    /// sparsely (a field holding its default value isn't in the JSON), so a
    /// fresh doc lacks e.g. `traceLevel` even though the GUI shows
    /// "Everything". Built from a real default Profile at runtime — the same
    /// source of truth the GUI decodes against — so values can't drift.
    /// Consulted for display + initial picker position only; nothing is
    /// written back unless the user actually changes a value.
    private lazy var fieldDefaults: [String: Any] = {
        let p = Profile(name: "", tool: .claude, authMode: .token)
        var d: [String: Any] = [
            // General
            "color": p.color.rawValue,
            "closeAction": p.closeAction.rawValue,
            "bootAtStartup": p.bootAtStartup,
            "comments": p.comments,
            // Agents
            "tool": p.tool.rawValue,
            "authMode": p.authMode.rawValue,
            "apiKeyRequiresApproval": p.apiKeyRequiresApproval,
            "bedrockModelID": p.bedrockModelID,
            // Local Models / Fusion
            "modelRouting": p.modelRouting.rawValue,
            "hybridCloudTokenBudget": p.hybridCloudTokenBudget,
            "hybridSoftTTFTSeconds": p.hybridSoftTTFTSeconds,
            "hybridLocalSplitPercent": p.hybridLocalSplitPercent,
            "fusionJudgeLocal": p.fusionJudgeLocal,
            // Tracing
            "traceLevel": p.traceLevel.rawValue,
            "privateMode": p.privateMode,
            // Resources / Appearance
            "memoryGB": p.memoryGB,
            "networkMode": p.networkMode.rawValue,
            "cursorShape": p.cursorShape.rawValue,
            "windowOpacity": p.windowOpacity,
            "fontLigatures": p.fontLigatures,
            // Credentials
            "gitUserName": p.gitUserName,
            "gitUserEmail": p.gitUserEmail,
            "digitalOceanTokenRequiresApproval": p.digitalOceanTokenRequiresApproval,
            // Prompt Injection (nested pane — flat keys are unique across panes)
            "detectSourceInjection": p.promptInjection.detectSourceInjection,
            "detectRulesInjection": p.promptInjection.detectRulesInjection,
            "onDetection": p.promptInjection.onDetection.rawValue,
            // Supply Chain (nested)
            "ageGateEnabled": p.supplyChain.ageGateEnabled,
            "ageGateDays": p.supplyChain.ageGateDays,
            "osvEnabled": p.supplyChain.osvEnabled,
            "osvSeverity": p.supplyChain.osvSeverity.rawValue,
            "socketAPIKey": p.supplyChain.socketAPIKey,
            "socketBlockCompromised": p.supplyChain.socketBlockCompromised,
            "socketBlockCVE": p.supplyChain.socketBlockCVE,
            "socketCVESeverity": p.supplyChain.socketCVESeverity.rawValue,
            "stripInstallScripts": p.supplyChain.stripInstallScripts,
            "lockfilePrompt": p.supplyChain.lockfilePrompt,
            // Guardrails (nested; keys are the integration names)
            "kubernetes": p.guardrails.kubernetes.rawValue,
            "aws": p.guardrails.aws.rawValue,
            "digitalOcean": p.guardrails.digitalOcean.rawValue,
            "docker": p.guardrails.docker.rawValue,
            "github": p.guardrails.github.rawValue,
            "gitlab": p.guardrails.gitlab.rawValue,
            "bitbucket": p.guardrails.bitbucket.rawValue,
        ]
        if let v = p.customFontSize { d["customFontSize"] = v }
        if let v = p.keyboardLayoutOverride { d["keyboardLayoutOverride"] = v }
        return d
    }()

    /// The doc's value for `key`, else its Profile default (sparse-JSON fix).
    private func fieldValue(_ doc: [String: Any], _ key: String) -> Any? {
        doc[key] ?? fieldDefaults[key]
    }

    private func fieldDisplay(_ doc: [String: Any], _ key: String, _ kind: FieldKind) -> String {
        switch kind {
        case .bool:   return (fieldValue(doc, key) as? Bool ?? false) ? "yes" : "no"
        case .int:    return (fieldValue(doc, key) as? Int).map(String.init) ?? "—"
        case .double: return (fieldValue(doc, key) as? Double).map { String($0) } ?? "—"
        case .pick:   return (fieldValue(doc, key) as? String) ?? "—"
        case .pickLabeled(let opts):
            let cur = fieldValue(doc, key) as? String ?? ""
            return opts.first(where: { $0.value == cur })?.label ?? (cur.isEmpty ? "—" : cur)
        case .modelPick:
            let id = fieldValue(doc, key) as? String ?? ""
            return id.isEmpty ? "—" : id
        case .text(let secret):
            let v = fieldValue(doc, key) as? String ?? ""
            if secret { return v.isEmpty ? "—" : "•••• (set)" }
            return v.isEmpty ? "—" : v
        }
    }

    /// Edit one field in place. Returns whether the value changed.
    private func editField(_ doc: inout [String: Any], key: String,
                           label: String, kind: FieldKind) -> Bool {
        switch kind {
        case .bool:
            let cur = fieldValue(doc, key) as? Bool ?? false
            let newV = tui.confirm("\(label)?", defaultYes: cur)
            if newV != cur { doc[key] = newV; return true }
            return false
        case .text(let secret):
            let cur = fieldValue(doc, key) as? String ?? ""
            guard let s = tui.prompt(label, secret: secret, initial: secret ? "" : cur,
                                     hint: secret ? "leave blank to keep the stored value" : nil)
            else { return false }
            if secret && s.isEmpty { return false }           // keep existing secret
            if s != cur { doc[key] = s; return true }
            return false
        case .int:
            let cur = fieldValue(doc, key) as? Int
            guard let s = tui.prompt(label, initial: cur.map(String.init) ?? "") else { return false }
            let t = s.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { return false }
            if let v = Int(t), v != cur { doc[key] = v; return true }
            return false
        case .double:
            let cur = fieldValue(doc, key) as? Double
            guard let s = tui.prompt(label, initial: cur.map { String($0) } ?? "") else { return false }
            let t = s.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { return false }
            if let v = Double(t), v != cur { doc[key] = v; return true }
            return false
        case .pick(let options):
            let cur = fieldValue(doc, key) as? String
            let initial = options.firstIndex(of: cur ?? "") ?? 0
            guard let i = tui.menu(title: label, items: options, initial: initial) else { return false }
            if options[i] != cur { doc[key] = options[i]; return true }
            return false
        case .pickLabeled(let opts):
            let cur = fieldValue(doc, key) as? String
            let initial = opts.firstIndex(where: { $0.value == cur }) ?? 0
            guard let i = tui.menu(title: label, items: opts.map { $0.label }, initial: initial) else { return false }
            if opts[i].value != cur { doc[key] = opts[i].value; return true }
            return false
        case .modelPick:
            let models = catalogModels()
            guard !models.isEmpty else {
                tui.pager(title: label, body: "The model catalog is empty or unreadable.")
                return false
            }
            let cur = fieldValue(doc, key) as? String
            // "None" first, then the whole catalog — ✓ marks installed models;
            // selecting an uninstalled one downloads it first (GUI parity).
            var items = ["None"]
            items.append(contentsOf: models.map { m in
                let badge = m.installed ? "✓" : String(format: "⬇ %.0f GB", m.sizeGB)
                return "\(m.label)  [\(m.id)]  \(badge)"
            })
            let initial = models.firstIndex(where: { $0.id == cur }).map { $0 + 1 } ?? 0
            guard let i = tui.menu(title: label, items: items,
                                   footer: "Enter select · ✓ installed · ⬇ downloads first",
                                   initial: initial) else { return false }
            if i == 0 {                                            // None → clear
                if (cur ?? "").isEmpty { return false }
                doc.removeValue(forKey: key); return true
            }
            let m = models[i - 1]
            if !m.installed {
                guard tui.confirm(String(format: "Download %@ (%.0f GB) now?", m.label, m.sizeGB),
                                  defaultYes: true) else { return false }
                // Hand the terminal to `model pull` so its live progress draws.
                tui.end()
                let status = runSelfInteractive(["model", "pull", m.id])
                tui.begin()
                guard status == 0 else {
                    tui.pager(title: "Download failed",
                              body: "`model pull \(m.id)` exited with status \(status).\nTry it from the Models menu for the full output.")
                    return false
                }
            }
            if m.id != cur { doc[key] = m.id; return true }
            return false
        }
    }

    /// Menu of fields; edit one at a time until Back. Returns whether anything
    /// changed. Operates on `doc` directly (pass a sub-dict for nested panes).
    private func editFields(title: String,
                            doc: inout [String: Any],
                            fields: [(key: String, label: String, kind: FieldKind)]) -> Bool {
        var changed = false
        while true {
            let rows = fields.map { "\($0.label):  \(fieldDisplay(doc, $0.key, $0.kind))" } + ["Back"]
            guard let sel = tui.menu(title: title, items: rows, footer: "Enter edit · q back") else {
                return changed
            }
            if sel >= fields.count { return changed }
            let f = fields[sel]
            if editField(&doc, key: f.key, label: f.label, kind: f.kind) { changed = true }
        }
    }

    /// Edit a nested policy object (doc[parent] = { … }) with the field engine.
    private func editNested(_ doc: inout [String: Any], parent: String, title: String,
                            fields: [(key: String, label: String, kind: FieldKind)]) -> Bool {
        var sub = doc[parent] as? [String: Any] ?? [:]
        let changed = editFields(title: title, doc: &sub, fields: fields)
        if changed { doc[parent] = sub }
        return changed
    }

    // MARK: Per-pane forms

    private func editGeneral(_ doc: inout [String: Any]) -> Bool {
        editFields(title: "General", doc: &doc, fields: [
            ("name",  "Name",  .text(secret: false)),
            ("color", "Color", .pick(["blue", "red", "green", "orange", "purple", "pink", "teal", "gray"])),
            ("keyboardLayoutOverride", "Keyboard layout", .text(secret: false)),
            ("keyRepeatDelayMs", "Key repeat delay", .int),
            ("keyRepeatRateHz", "Key repeat rate", .int),
            ("closeAction", "When closing the window", .pickLabeled([
                ("Run in the background", "background"), ("Suspend", "suspend"),
                ("Shut down", "shutdown"), ("Ask", "ask")])),
            ("bootAtStartup", "Start this VM at login", .bool),
            ("comments", "Notes (optional)", .text(secret: false)),
        ])
    }

    private func editAgents(_ doc: inout [String: Any]) -> Bool {
        editFields(title: "Agents", doc: &doc, fields: [
            ("tool", "Primary tool", .pickLabeled([
                ("Claude Code", "claude"), ("Codex", "codex"), ("Grok Build", "grok")])),
            ("authMode", "Auth mode", .pickLabeled([
                ("API token", "token"), ("Subscription (interactive login)", "subscription"),
                ("Bedrock (AWS)", "bedrock"), ("Local model", "local")])),
            ("apiKey", "API key", .text(secret: true)),
            ("apiKeyRequiresApproval", "Require approval to use", .bool),
            ("bedrockModelID", "Default Model ID", .text(secret: false)),
        ])
    }

    private func editLocalModels(_ doc: inout [String: Any]) -> Bool {
        editFields(title: "Local Models", doc: &doc, fields: [
            ("modelRouting", "Routing", .pickLabeled([
                ("Cloud", "cloud"), ("Local — always on-device", "local"),
                ("Hybrid — cloud, fall back to local", "hybrid")])),
            ("activeModelID", "Active local model", .modelPick),
            ("hybridCloudTokenBudget", "Hybrid: cloud token budget / 24h (0 = ∞)", .int),
            ("hybridSoftTTFTSeconds", "Hybrid: soft TTFT fallback (seconds)", .double),
            ("hybridLocalSplitPercent", "Hybrid: % of sessions pinned local", .int),
        ])
    }

    private func editResources(_ doc: inout [String: Any]) -> Bool {
        editFields(title: "Resources", doc: &doc, fields: [
            ("memoryGB", "VM RAM", .int),
            ("networkMode", "Network", .pickLabeled([("NAT", "nat"), ("Bridged", "bridged")])),
        ])
    }

    private func editTracing(_ doc: inout [String: Any]) -> Bool {
        editFields(title: "Tracing", doc: &doc, fields: [
            ("traceLevel", "Session trace", .pickLabeled([
                ("Off", "off"), ("Activity only", "activity"),
                ("AI request details", "aiDetails"), ("Everything", "all")])),
            ("privateMode", "Private mode", .bool),
        ])
    }

    private func editAppearance(_ doc: inout [String: Any]) -> Bool {
        editFields(title: "Appearance", doc: &doc, fields: [
            ("customFontFamily", "Font", .text(secret: false)),
            ("customFontSize", "Font size", .int),
            ("cursorShape", "Cursor", .pickLabeled([
                ("Block", "block"), ("Beam (I-cursor)", "beam"), ("Underline", "underline")])),
            ("customBackgroundHex", "Background", .text(secret: false)),
            ("customForegroundHex", "Text", .text(secret: false)),
            ("windowOpacity", "Opacity", .double),
            ("fontLigatures", "Ligatures", .bool),
        ])
    }

    private func editPromptInjection(_ doc: inout [String: Any]) -> Bool {
        editNested(&doc, parent: "promptInjection", title: "Prompt Injection", fields: [
            ("detectSourceInjection", "Detect prompt injection in source code", .bool),
            ("detectRulesInjection", "Detect rogue instructions in CLAUDE.md files and similar", .bool),
            ("onDetection", "When an injection is detected", .pickLabeled([
                ("Log but continue", "log"), ("Ask me what to do", "ask"),
                ("Block unilaterally", "block")])),
        ])
    }

    private func editSupplyChain(_ doc: inout [String: Any]) -> Bool {
        let severity: [(label: String, value: String)] = [
            ("Low and above", "low"), ("Medium and above", "medium"),
            ("High and above", "high"), ("Critical only", "critical")]
        return editNested(&doc, parent: "supplyChain", title: "Supply Chain", fields: [
            ("ageGateEnabled", "Refuse packages younger than the cutoff", .bool),
            ("ageGateDays", "Minimum age", .int),
            ("osvEnabled", "Look up packages on api.osv.dev (free, no key required)", .bool),
            ("osvSeverity", "Block at severity", .pickLabeled(severity)),
            ("socketAPIKey", "API key", .text(secret: true)),
            ("socketBlockCompromised", "Block compromised packages (rogue install scripts, malware-flagged, typosquats, suspicious telemetry)", .bool),
            ("socketBlockCVE", "Block packages with known CVEs", .bool),
            ("socketCVESeverity", "CVE block threshold", .pickLabeled(severity)),
            ("stripInstallScripts", "Strip preinstall / install / postinstall / prepare from npm tarballs on the fly", .bool),
            ("lockfilePrompt", "Prompt before passing lockfile-pinned tarballs through unmodified (npm ci, pip --require-hashes)", .bool),
        ])
    }

    private func editGuardrails(_ doc: inout [String: Any]) -> Bool {
        let modes: [(label: String, value: String)] = [
            ("Off", "off"), ("Prompt before write", "promptOnWrite"),
            ("Block destructive", "destructive"), ("Read-only", "readOnly")]
        return editNested(&doc, parent: "guardrails", title: "Guardrails", fields: [
            ("kubernetes", "Kubernetes", .pickLabeled(modes)),
            ("aws", "AWS", .pickLabeled(modes)),
            ("digitalOcean", "DigitalOcean", .pickLabeled(modes)),
            ("docker", "Docker registries", .pickLabeled(modes)),
            ("github", "GitHub", .pickLabeled(modes)),
            ("gitlab", "GitLab", .pickLabeled(modes)),
            ("bitbucket", "Bitbucket", .pickLabeled(modes)),
        ])
    }

    private func editFusion(_ doc: inout [String: Any]) -> Bool {
        var changed = false
        while true {
            let legs = (doc["fusionLegs"] as? [String]) ?? []
            let rows = [
                "Models to fuse:  \(legs.isEmpty ? "—" : legs.joined(separator: ", "))",
                "Provider:  \((doc["fusionJudgeProvider"] as? String) ?? "—")",
                "Model:  \((doc["fusionJudgeModel"] as? String) ?? "—")",
                "Judge on local engine:  \((doc["fusionJudgeLocal"] as? Bool ?? false) ? "yes" : "no")",
                "Local model:  \((doc["fusionLocalLeg"] as? String) ?? "—")",
                "Back",
            ]
            guard let sel = tui.menu(title: "Fusion", items: rows, footer: "Enter edit · q back") else {
                return changed
            }
            switch sel {
            case 0:
                let tools = ["claude", "codex", "grok"]
                let on = Set(legs.compactMap { tools.firstIndex(of: $0) })
                if let picked = tui.checklist(title: "Models to fuse (≥2 to engage)",
                                              items: ["Claude", "Codex", "Grok"], initiallyOn: on) {
                    doc["fusionLegs"] = picked.sorted().map { tools[$0] }
                    changed = true
                }
            case 1: if editField(&doc, key: "fusionJudgeProvider", label: "Provider",
                                 kind: .pick(["claude", "codex", "grok"])) { changed = true }
            case 2: if editField(&doc, key: "fusionJudgeModel", label: "Model",
                                 kind: .text(secret: false)) { changed = true }
            case 3: if editField(&doc, key: "fusionJudgeLocal", label: "Judge on local engine",
                                 kind: .bool) { changed = true }
            case 4: if editField(&doc, key: "fusionLocalLeg", label: "Local model",
                                 kind: .modelPick) { changed = true }
            default: return changed
            }
        }
    }

    private func editFolders(_ doc: inout [String: Any]) -> Bool {
        var folders = (doc["folderPaths"] as? [String]) ?? []
        var changed = false
        while true {
            var rows = folders.map { "🗀 \($0)" }
            rows.append("＋ Add folder")
            rows.append("Back")
            guard let sel = tui.menu(title: "Shared folders (max 8)", items: rows,
                                     footer: "Enter: remove · q back") else { break }
            if sel == rows.count - 1 { break }                    // Back
            if sel == rows.count - 2 {                            // Add
                guard folders.count < 8,
                      let p = tui.prompt("Host folder path (mounted at ~/<name>)"),
                      !p.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                folders.append((p.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath)
                changed = true
            } else if sel >= 0, sel < folders.count {             // remove a row
                if tui.confirm("Remove \(folders[sel])?") { folders.remove(at: sel); changed = true }
            }
        }
        if changed { doc["folderPaths"] = folders }
        return changed
    }

    private func editEnvironment(_ doc: inout [String: Any]) -> Bool {
        var vars = (doc["environmentVariables"] as? [[String: Any]]) ?? []
        var changed = false
        while true {
            var rows = vars.map { "\($0["name"] as? String ?? "?")=\($0["value"] as? String ?? "")" }
            rows.append("＋ Add variable")
            rows.append("Back")
            guard let sel = tui.menu(title: "Environment variables", items: rows,
                                     footer: "Enter: edit/remove · q back") else { break }
            if sel == rows.count - 1 { break }
            if sel == rows.count - 2 {
                guard let n = tui.prompt("Variable name (e.g. FOO)"),
                      !n.trimmingCharacters(in: .whitespaces).isEmpty,
                      let v = tui.prompt("Value for \(n)") else { continue }
                vars.append(["id": UUID().uuidString,
                             "name": n.trimmingCharacters(in: .whitespaces), "value": v])
                changed = true
            } else if sel >= 0, sel < vars.count {
                let name = vars[sel]["name"] as? String ?? "?"
                guard let act = tui.menu(title: name, items: ["Edit value", "Remove", "Cancel"]) else { continue }
                if act == 0, let v = tui.prompt("Value for \(name)", initial: vars[sel]["value"] as? String ?? "") {
                    vars[sel]["value"] = v; changed = true
                } else if act == 1 {
                    vars.remove(at: sel); changed = true
                }
            }
        }
        if changed { doc["environmentVariables"] = vars }
        return changed
    }

    // MARK: MCP servers (native list editor — mirrors the GUI's MCP pane)

    private func editMCP(_ doc: inout [String: Any]) -> Bool {
        var servers = (doc["mcpServers"] as? [[String: Any]]) ?? []
        var changed = false
        while true {
            var rows = servers.map { s -> String in
                let name = s["name"] as? String ?? "?"
                let tr = s["transport"] as? String ?? "stdio"
                let off = (s["enabled"] as? Bool ?? true) ? "" : "  (disabled)"
                return "\(name)  ·  \(tr)\(off)"
            }
            rows.append("＋ Add MCP server")
            rows.append("Back")
            guard let sel = tui.menu(title: "MCP servers", items: rows,
                                     footer: "Enter: edit/remove · q back",
                                     header: ["Model Context Protocol servers this workspace's agent can call."]) else { break }
            if sel == rows.count - 1 { break }
            if sel == rows.count - 2 {
                guard let name = tui.prompt("Server name (e.g. github)"),
                      !name.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                let ti = tui.menu(title: "Transport", items: ["stdio", "http"]) ?? 0
                var s: [String: Any] = [
                    "id": UUID().uuidString,
                    "name": name.trimmingCharacters(in: .whitespaces),
                    "transport": ti == 0 ? "stdio" : "http",
                    "command": "", "arguments": [String](), "url": "",
                    "environment": [[String: Any]](),
                    "bearerTokenEnvVar": "", "bearerToken": "",
                    "enabled": true, "rawJSON": "",
                ]
                _ = editMCPServer(&s)
                servers.append(s); changed = true
            } else if sel >= 0, sel < servers.count {
                guard let act = tui.menu(title: servers[sel]["name"] as? String ?? "server",
                                         items: ["Edit", "Remove", "Cancel"]) else { continue }
                if act == 0 { if editMCPServer(&servers[sel]) { changed = true } }
                else if act == 1, tui.confirm("Remove \(servers[sel]["name"] as? String ?? "server")?") {
                    servers.remove(at: sel); changed = true
                }
            }
        }
        if changed { doc["mcpServers"] = servers }
        return changed
    }

    private func editMCPServer(_ s: inout [String: Any]) -> Bool {
        var changed = false
        while true {
            let transport = s["transport"] as? String ?? "stdio"
            let args = (s["arguments"] as? [String]) ?? []
            var rows = ["Name:  \(s["name"] as? String ?? "—")",
                        "Transport:  \(transport.uppercased())"]
            if transport == "stdio" {
                rows.append("Command:  \(s["command"] as? String ?? "—")")
                rows.append("Arguments:  \(args.isEmpty ? "—" : args.joined(separator: " "))")
            } else {
                rows.append("URL:  \(s["url"] as? String ?? "—")")
                rows.append("Env var name:  \(s["bearerTokenEnvVar"] as? String ?? "—")")
                rows.append("Token:  \((s["bearerToken"] as? String ?? "").isEmpty ? "—" : "•••• (set)")")
            }
            rows.append("Enabled:  \((s["enabled"] as? Bool ?? true) ? "yes" : "no")")
            rows.append("Back")
            guard let sel = tui.menu(title: s["name"] as? String ?? "MCP server", items: rows,
                                     footer: "Enter edit · q back") else { return changed }
            let backIdx = rows.count - 1, enabledIdx = backIdx - 1
            if sel == backIdx { return changed }
            if sel == 0 { if editField(&s, key: "name", label: "Name", kind: .text(secret: false)) { changed = true } }
            else if sel == 1 { if editField(&s, key: "transport", label: "Transport", kind: .pickLabeled([("STDIO", "stdio"), ("HTTP", "http")])) { changed = true } }
            else if sel == enabledIdx { if editField(&s, key: "enabled", label: "Enabled", kind: .bool) { changed = true } }
            else if transport == "stdio" {
                if sel == 2 { if editField(&s, key: "command", label: "Command", kind: .text(secret: false)) { changed = true } }
                else if sel == 3, let v = tui.prompt("Arguments (space-separated)", initial: args.joined(separator: " ")) {
                    s["arguments"] = v.split(separator: " ").map(String.init); changed = true
                }
            } else {
                if sel == 2 { if editField(&s, key: "url", label: "URL", kind: .text(secret: false)) { changed = true } }
                else if sel == 3 { if editField(&s, key: "bearerTokenEnvVar", label: "Env var name", kind: .text(secret: false)) { changed = true } }
                else if sel == 4 { if editField(&s, key: "bearerToken", label: "Token", kind: .text(secret: true)) { changed = true } }
            }
        }
    }

    // MARK: Credentials (native forms — mirrors the GUI's Credentials pane)

    private func editCredentials(_ doc: inout [String: Any]) -> Bool {
        var changed = false
        func count(_ k: String) -> Int { (doc[k] as? [[String: Any]])?.count ?? 0 }
        // The GUI's host classifiers (ProfileViews isGitHub/isGitLab/isBitbucket),
        // verbatim, so the three forge sections partition the shared
        // gitHTTPSCredentials collection exactly like the GUI does.
        func isGitHub(_ h: String) -> Bool { let s = h.lowercased(); return s == "github.com" || s.hasSuffix(".github.com") }
        func isGitLab(_ h: String) -> Bool { let s = h.lowercased(); return s == "gitlab.com" || s.hasPrefix("gitlab.") }
        func isBitbucket(_ h: String) -> Bool { h.lowercased() == "bitbucket.org" }
        func forgeCount(_ m: (String) -> Bool) -> Int {
            ((doc["gitHTTPSCredentials"] as? [[String: Any]]) ?? [])
                .filter { m(($0["host"] as? String) ?? "") }.count
        }
        func dbCount(_ engine: String) -> Int {
            ((doc["httpDatabases"] as? [[String: Any]]) ?? [])
                .filter { ($0["engine"] as? String) == engine }.count
        }
        while true {
            let gitName = doc["gitUserName"] as? String ?? ""
            let gen = (doc["generateSSH"] as? Bool ?? false)
                || !((doc["sshPublicKey"] as? String ?? "").isEmpty)
            let sshCount = count("importedSSHKeys") + (gen ? 1 : 0)
            let doSet = !((doc["digitalOceanToken"] as? String ?? "").isEmpty)
            let aws = (doc["awsCredentials"] as? [String: Any]) ?? [:]
            let awsSet = !((aws["accessKeyID"] as? String ?? "").isEmpty)
                || !((aws["ssoProfileName"] as? String ?? "").isEmpty)
            // The same sections, in the same order, as the GUI Credentials pane.
            let rows = [
                "Git Identity  \(gitName.isEmpty ? "—" : gitName)",
                "SSH Keys  (\(sshCount))",
                "GitHub Tokens  (\(forgeCount(isGitHub)))",
                "GitLab Tokens  (\(forgeCount(isGitLab)))",
                "Bitbucket Tokens  (\(forgeCount(isBitbucket)))",
                "Kubernetes  (\(count("kubeconfigs")))",
                "DigitalOcean  (\(doSet ? 1 : 0))",
                "AWS  (\(awsSet ? 1 : 0))",
                "Container Registries  (\(count("dockerRegistries")))",
                "MongoDB  (\(dbCount("mongoDataAPI")))",
                "ClickHouse  (\(dbCount("clickHouse")))",
                "Elasticsearch  (\(dbCount("elasticsearch")))",
                "Other API keys  (\(count("manualTokens")))",
                "Back",
            ]
            guard let sel = tui.menu(title: "Credentials", items: rows, footer: "Enter · q back") else { return changed }
            switch sel {
            case 0: if editFields(title: "Git Identity", doc: &doc, fields: [
                        ("gitUserName", "user.name", .text(secret: false)),
                        ("gitUserEmail", "user.email", .text(secret: false))]) { changed = true }
            case 1: if editSSHKeys(&doc) { changed = true }
            case 2: if editGitTokens(&doc, title: "GitHub Tokens", displayName: "GitHub",
                                     defaultHost: "github.com", matches: isGitHub) { changed = true }
            case 3: if editGitTokens(&doc, title: "GitLab Tokens", displayName: "GitLab",
                                     defaultHost: "gitlab.com", matches: isGitLab) { changed = true }
            case 4: if editGitTokens(&doc, title: "Bitbucket Tokens", displayName: "Bitbucket",
                                     defaultHost: "bitbucket.org", matches: isBitbucket) { changed = true }
            case 5: if editKubeconfigs(&doc) { changed = true }
            case 6: if editFields(title: "DigitalOcean", doc: &doc, fields: [
                        ("digitalOceanToken", "API token (dop_v1_…)", .text(secret: true)),
                        ("digitalOceanTokenRequiresApproval", "Require approval to use", .bool)]) { changed = true }
            case 7: if editAWS(&doc) { changed = true }
            case 8: if editCredList(&doc, key: "dockerRegistries", title: "Container Registries",
                                    summary: { "\($0["username"] as? String ?? "?")@\($0["host"] as? String ?? "?")" },
                                    blank: { ["id": UUID().uuidString, "host": "", "username": "", "password": "", "requireApproval": false] },
                                    fields: [("host", "Host", .text(secret: false)),
                                             ("username", "Username", .text(secret: false)),
                                             ("password", "Password", .text(secret: true)),
                                             ("requireApproval", "Require approval to use", .bool)]) { changed = true }
            case 9: if editDatabaseSection(&doc, title: "MongoDB", engine: "mongoDataAPI",
                                           defaultAuth: "apiKey") { changed = true }
            case 10: if editDatabaseSection(&doc, title: "ClickHouse", engine: "clickHouse",
                                            defaultAuth: "basic") { changed = true }
            case 11: if editDatabaseSection(&doc, title: "Elasticsearch", engine: "elasticsearch",
                                            defaultAuth: "basic") { changed = true }
            case 12: if editCredList(&doc, key: "manualTokens", title: "Other API keys",
                                    summary: { "\($0["name"] as? String ?? "?")  → $\($0["envVarName"] as? String ?? "")" },
                                    blank: { ["id": UUID().uuidString, "name": "", "realValue": "", "envVarName": "", "hostFilter": "", "requireApproval": false] },
                                    fields: [("name", "Name", .text(secret: false)),
                                             ("realValue", "Real secret", .text(secret: true)),
                                             ("envVarName", "Environment variable", .text(secret: false)),
                                             ("hostFilter", "API host (optional)", .text(secret: false)),
                                             ("requireApproval", "Require approval to use", .bool)]) { changed = true }
            default: return changed
            }
        }
    }

    /// One git-forge token section (GitHub / GitLab / Bitbucket). Operates on a
    /// FILTERED view of the shared gitHTTPSCredentials collection and merges
    /// back into the full array — exactly the GUI's sectioning. "Add token"
    /// prefills the forge's default host and (like the GUI) suggests git
    /// user.name when it has no spaces.
    private func editGitTokens(_ doc: inout [String: Any], title: String, displayName: String,
                               defaultHost: String, matches: (String) -> Bool) -> Bool {
        var all = (doc["gitHTTPSCredentials"] as? [[String: Any]]) ?? []
        var changed = false
        let fields: [(key: String, label: String, kind: FieldKind)] = [
            ("host", "Host", .text(secret: false)),
            ("username", "Username", .text(secret: false)),
            ("token", "Personal access token", .text(secret: true)),
            ("requireApproval", "Require approval to use", .bool),
        ]
        while true {
            let visible = all.indices.filter { matches((all[$0]["host"] as? String) ?? "") }
            var rows = visible.map { i in
                "\(all[i]["username"] as? String ?? "?")@\(all[i]["host"] as? String ?? "?")"
            }
            rows.append("＋ Add token"); rows.append("Back")
            let header = visible.isEmpty ? ["No \(displayName) tokens configured."] : []
            guard let sel = tui.menu(title: title, items: rows,
                                     footer: "Enter: edit/remove · q back", header: header) else { break }
            if sel == rows.count - 1 { break }
            if sel == rows.count - 2 {
                let un = (doc["gitUserName"] as? String ?? "").trimmingCharacters(in: .whitespaces)
                var row: [String: Any] = ["id": UUID().uuidString, "host": defaultHost,
                                          "username": (!un.isEmpty && !un.contains(" ")) ? un : "",
                                          "token": "", "requireApproval": false]
                if editFields(title: title, doc: &row, fields: fields) { all.append(row); changed = true }
            } else if sel >= 0, sel < visible.count {
                let i = visible[sel]
                guard let act = tui.menu(title: rows[sel], items: ["Edit", "Remove", "Cancel"]) else { continue }
                if act == 0 { if editFields(title: title, doc: &all[i], fields: fields) { changed = true } }
                else if act == 1, tui.confirm("Remove this token?") { all.remove(at: i); changed = true }
            }
        }
        if changed { doc["gitHTTPSCredentials"] = all }
        return changed
    }

    /// AWS — auth-method aware, like the GUI: Static keys (access/secret/
    /// session/region) vs SSO / Identity Center (profile name; the "Grant
    /// access to ~/.aws" step is a host folder-permission action, GUI-only).
    private func editAWS(_ doc: inout [String: Any]) -> Bool {
        var aws = (doc["awsCredentials"] as? [String: Any]) ?? [:]
        var changed = false
        while true {
            let mode = aws["authMode"] as? String ?? "staticKeys"
            var rows = ["Auth method:  \(mode == "ssoProfile" ? "SSO / Identity Center" : "Static keys")"]
            if mode == "ssoProfile" {
                rows.append("SSO profile:  \(aws["ssoProfileName"] as? String ?? "—")")
            } else {
                rows.append("Access key ID:  \(aws["accessKeyID"] as? String ?? "—")")
                rows.append("Secret access key:  \((aws["secretAccessKey"] as? String ?? "").isEmpty ? "—" : "•••• (set)")")
                rows.append("Session token:  \((aws["sessionToken"] as? String ?? "").isEmpty ? "—" : "•••• (set)")")
                rows.append("Default region:  \(aws["region"] as? String ?? "—")")
            }
            rows.append("Require approval to use:  \((aws["requireApproval"] as? Bool ?? false) ? "yes" : "no")")
            rows.append("Back")
            guard let sel = tui.menu(title: "AWS", items: rows, footer: "Enter edit · q back") else { break }
            let backIdx = rows.count - 1, approvalIdx = backIdx - 1
            if sel == backIdx { break }
            if sel == 0 {
                if editField(&aws, key: "authMode", label: "Auth method", kind: .pickLabeled([
                    ("Static keys", "staticKeys"), ("SSO / Identity Center", "ssoProfile")])) { changed = true }
            } else if sel == approvalIdx {
                if editField(&aws, key: "requireApproval", label: "Require approval to use", kind: .bool) { changed = true }
            } else if mode == "ssoProfile" {
                if sel == 1, editField(&aws, key: "ssoProfileName", label: "SSO profile", kind: .text(secret: false)) { changed = true }
            } else {
                switch sel {
                case 1: if editField(&aws, key: "accessKeyID", label: "Access key ID", kind: .text(secret: false)) { changed = true }
                case 2: if editField(&aws, key: "secretAccessKey", label: "Secret access key", kind: .text(secret: true)) { changed = true }
                case 3: if editField(&aws, key: "sessionToken", label: "Session token", kind: .text(secret: true)) { changed = true }
                case 4: if editField(&aws, key: "region", label: "Default region", kind: .text(secret: false)) { changed = true }
                default: break
                }
            }
        }
        if changed { doc["awsCredentials"] = aws }
        return changed
    }

    // SSH Keys — the generated keypair toggle + list/remove of imported keys.
    private func editSSHKeys(_ doc: inout [String: Any]) -> Bool {
        var changed = false
        var imported = (doc["importedSSHKeys"] as? [[String: Any]]) ?? []
        while true {
            let gen = doc["generateSSH"] as? Bool ?? false
            var rows = ["Generate an ed25519 keypair:  \(gen ? "yes" : "no")"]
            for k in imported {
                rows.append("🔑 \((k["label"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (k["filename"] as? String ?? "imported key"))")
            }
            rows.append("Back")
            guard let sel = tui.menu(title: "SSH Keys", items: rows, footer: "Enter · q back",
                                     header: ["Import a key from the GUI; here you can toggle generation and remove imported keys."]) else { return changed }
            if sel == 0 {
                if editField(&doc, key: "generateSSH", label: "Generate an ed25519 keypair", kind: .bool) { changed = true }
            } else if sel == rows.count - 1 {
                return changed
            } else {
                let idx = sel - 1
                if idx >= 0, idx < imported.count,
                   tui.confirm("Remove imported key “\(imported[idx]["label"] as? String ?? imported[idx]["filename"] as? String ?? "")”?") {
                    imported.remove(at: idx); doc["importedSSHKeys"] = imported; changed = true
                }
            }
        }
    }

    // Kubernetes — kubeconfig contexts (server / CA / namespace / auth).
    private func editKubeconfigs(_ doc: inout [String: Any]) -> Bool {
        var items = (doc["kubeconfigs"] as? [[String: Any]]) ?? []
        var changed = false
        while true {
            var rows = items.map { "\($0["name"] as? String ?? "?")  ·  \($0["serverURL"] as? String ?? "")" }
            rows.append("＋ Add context"); rows.append("Back")
            guard let sel = tui.menu(title: "Kubernetes", items: rows, footer: "Enter: edit/remove · q back") else { break }
            if sel == rows.count - 1 { break }
            if sel == rows.count - 2 {
                var k: [String: Any] = ["id": UUID().uuidString, "name": "", "serverURL": "", "caCertPEM": "",
                                        "namespace": "", "auth": ["kind": "bearerToken", "token": ""], "requireApproval": false]
                if editKubeconfig(&k) { items.append(k); changed = true }
            } else if sel >= 0, sel < items.count {
                guard let act = tui.menu(title: items[sel]["name"] as? String ?? "context", items: ["Edit", "Remove", "Cancel"]) else { continue }
                if act == 0 { if editKubeconfig(&items[sel]) { changed = true } }
                else if act == 1, tui.confirm("Remove this context?") { items.remove(at: sel); changed = true }
            }
        }
        if changed { doc["kubeconfigs"] = items }
        return changed
    }

    private func editKubeconfig(_ k: inout [String: Any]) -> Bool {
        var changed = false
        while true {
            let auth = (k["auth"] as? [String: Any]) ?? ["kind": "bearerToken"]
            let kind = auth["kind"] as? String ?? "bearerToken"
            let authLabel = kind == "clientCert" ? "Client certificate" : (kind == "execPlugin" ? "Exec plugin" : "Bearer token")
            let rows = [
                "Name:  \(k["name"] as? String ?? "—")",
                "Server:  \(k["serverURL"] as? String ?? "—")",
                "CA cert:  \((k["caCertPEM"] as? String ?? "").isEmpty ? "—" : "•••• (set)")",
                "Namespace:  \(k["namespace"] as? String ?? "—")",
                "Auth:  \(authLabel)",
                "Require approval to use:  \((k["requireApproval"] as? Bool ?? false) ? "yes" : "no")",
                "Back",
            ]
            guard let sel = tui.menu(title: k["name"] as? String ?? "context", items: rows, footer: "Enter edit · q back") else { return changed }
            switch sel {
            case 0: if editField(&k, key: "name", label: "Name", kind: .text(secret: false)) { changed = true }
            case 1: if editField(&k, key: "serverURL", label: "Server", kind: .text(secret: false)) { changed = true }
            case 2: if editField(&k, key: "caCertPEM", label: "CA cert (PEM)", kind: .text(secret: true)) { changed = true }
            case 3: if editField(&k, key: "namespace", label: "Namespace", kind: .text(secret: false)) { changed = true }
            case 4: var a = auth; if editKubeAuth(&a) { k["auth"] = a; changed = true }
            case 5: if editField(&k, key: "requireApproval", label: "Require approval to use", kind: .bool) { changed = true }
            default: return changed
            }
        }
    }

    private func editKubeAuth(_ auth: inout [String: Any]) -> Bool {
        var changed = false
        while true {
            let kind = auth["kind"] as? String ?? "bearerToken"
            var rows = ["Method:  \(kind == "clientCert" ? "Client certificate" : (kind == "execPlugin" ? "Exec plugin" : "Bearer token"))"]
            if kind == "clientCert" {
                rows.append("Cert PEM:  \((auth["cert"] as? String ?? "").isEmpty ? "—" : "•••• (set)")")
                rows.append("Key PEM:  \((auth["key"] as? String ?? "").isEmpty ? "—" : "•••• (set)")")
            } else if kind == "execPlugin" {
                rows.append("Command:  \(auth["command"] as? String ?? "—")")
                rows.append("Args:  \((auth["args"] as? [String])?.joined(separator: " ") ?? "—")")
                rows.append("Refresh:  \((auth["refreshSeconds"] as? Int).map(String.init) ?? "—")")
            } else {
                rows.append("Token:  \((auth["token"] as? String ?? "").isEmpty ? "—" : "•••• (set)")")
            }
            rows.append("Back")
            guard let sel = tui.menu(title: "Auth", items: rows, footer: "Enter edit · q back") else { return changed }
            if sel == 0 {
                if editField(&auth, key: "kind", label: "Auth method", kind: .pickLabeled([
                    ("Bearer token", "bearerToken"), ("Client certificate", "clientCert"), ("Exec plugin", "execPlugin")])) { changed = true }
            } else if sel == rows.count - 1 {
                return changed
            } else if kind == "clientCert" {
                if sel == 1 { if editField(&auth, key: "cert", label: "Cert PEM", kind: .text(secret: true)) { changed = true } }
                else if sel == 2 { if editField(&auth, key: "key", label: "Key PEM", kind: .text(secret: true)) { changed = true } }
            } else if kind == "execPlugin" {
                if sel == 1 { if editField(&auth, key: "command", label: "Command", kind: .text(secret: false)) { changed = true } }
                else if sel == 2, let v = tui.prompt("Args (space-separated)", initial: (auth["args"] as? [String])?.joined(separator: " ") ?? "") {
                    auth["args"] = v.split(separator: " ").map(String.init); changed = true
                } else if sel == 3 { if editField(&auth, key: "refreshSeconds", label: "Refresh (seconds)", kind: .int) { changed = true } }
            } else {
                if sel == 1 { if editField(&auth, key: "token", label: "Token", kind: .text(secret: true)) { changed = true } }
            }
        }
    }

    /// One database engine section (MongoDB / ClickHouse / Elasticsearch) —
    /// exactly the GUI's sectioning: filters the shared httpDatabases
    /// collection by engine, merges edits back into the full array, and "Add"
    /// presets the engine + its GUI default auth (Mongo→API key, others→Basic).
    /// Engine is fixed by the section, so the row (like the GUI's) doesn't
    /// expose it.
    private func editDatabaseSection(_ doc: inout [String: Any], title: String,
                                     engine: String, defaultAuth: String) -> Bool {
        var all = (doc["httpDatabases"] as? [[String: Any]]) ?? []
        var changed = false
        let fields: [(key: String, label: String, kind: FieldKind)] = [
            ("name", "Name (optional)", .text(secret: false)),
            ("host", "Host", .text(secret: false)),
            ("auth", "Authentication", .pickLabeled([
                ("Username + password", "basic"), ("API key", "apiKey"), ("Bearer token", "bearer")])),
            ("username", "Username", .text(secret: false)),
            ("secret", "Secret", .text(secret: true)),
        ]
        while true {
            let visible = all.indices.filter { (all[$0]["engine"] as? String) == engine }
            var rows = visible.map { i -> String in
                let n = (all[i]["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                return "\(n ?? title)  ·  \(all[i]["host"] as? String ?? "")"
            }
            rows.append("＋ Add"); rows.append("Back")
            let header = visible.isEmpty ? ["No endpoints configured."] : []
            guard let sel = tui.menu(title: title, items: rows,
                                     footer: "Enter: edit/remove · q back", header: header) else { break }
            if sel == rows.count - 1 { break }
            if sel == rows.count - 2 {
                var d: [String: Any] = ["id": UUID().uuidString, "name": "", "engine": engine,
                                        "host": "", "auth": defaultAuth, "username": "",
                                        "secret": "", "envVars": [String]()]
                if editFields(title: title, doc: &d, fields: fields) { all.append(d); changed = true }
            } else if sel >= 0, sel < visible.count {
                let i = visible[sel]
                guard let act = tui.menu(title: rows[sel], items: ["Edit", "Remove", "Cancel"]) else { continue }
                if act == 0 { if editFields(title: title, doc: &all[i], fields: fields) { changed = true } }
                else if act == 1, tui.confirm("Remove this endpoint?") { all.remove(at: i); changed = true }
            }
        }
        if changed { doc["httpDatabases"] = all }
        return changed
    }

    /// Generic list-of-credentials editor: list rows via `summary`, add via
    /// `blank`, and edit each row's `fields` with the field engine.
    private func editCredList(_ doc: inout [String: Any], key: String, title: String,
                              summary: ([String: Any]) -> String,
                              blank: () -> [String: Any],
                              fields: [(key: String, label: String, kind: FieldKind)]) -> Bool {
        var items = (doc[key] as? [[String: Any]]) ?? []
        var changed = false
        while true {
            var rows = items.map(summary)
            rows.append("＋ Add"); rows.append("Back")
            guard let sel = tui.menu(title: title, items: rows, footer: "Enter: edit/remove · q back") else { break }
            if sel == rows.count - 1 { break }
            if sel == rows.count - 2 {
                var row = blank()
                if editFields(title: title, doc: &row, fields: fields) { items.append(row); changed = true }
            } else if sel >= 0, sel < items.count {
                guard let act = tui.menu(title: summary(items[sel]), items: ["Edit", "Remove", "Cancel"]) else { continue }
                if act == 0 { if editFields(title: title, doc: &items[sel], fields: fields) { changed = true } }
                else if act == 1, tui.confirm("Remove this entry?") { items.remove(at: sel); changed = true }
            }
        }
        if changed { doc[key] = items }
        return changed
    }

    /// `kubectl edit`-style round-trip: fetch the full profile JSON, open it in
    /// $EDITOR on the user's terminal, PUT the result back. Secrets come back
    /// blank — blank keeps the stored value; a typed value replaces it.
    private func editWorkspaceJSON(id: String, name: String) {
        guard let cur = try? client.request(
            "GET", "/profiles/\(ControlClient.encodeSegment(id))?full=1"), cur.status == 200 else {
            tui.pager(title: "Edit \(name)", body: "Couldn't fetch the workspace configuration.")
            return
        }
        // Hand the terminal to $EDITOR (leave the alt-screen/raw TUI first).
        tui.end()
        var putResult: String?
        do {
            if let edited = try editJSONInEditor(cur.json) {
                let resp = try client.request(
                    "PUT", "/profiles/\(ControlClient.encodeSegment(id))", body: edited)
                if resp.status == 200, (resp.json["ok"] as? Bool) == true {
                    putResult = "Saved \(name)."
                } else {
                    putResult = (resp.json["error"] as? String) ?? "Save failed (HTTP \(resp.status))."
                }
            } else {
                putResult = "No changes."
            }
        } catch {
            putResult = "Not saved: \(error.localizedDescription)"
        }
        tui.begin()
        if let putResult { tui.pager(title: "Edit \(name)", body: putResult) }
    }

    /// `vm routing cloud|local|hybrid` from the menu.
    private func chooseRouting(id: String, name: String, current: String) {
        let modes = ["cloud", "local", "hybrid"]
        let initial = modes.firstIndex(of: current) ?? 0
        guard let sel = tui.menu(title: "Routing for \(name)",
                                 items: ["Cloud", "Local", "Hybrid"],
                                 footer: "Enter select · q back", initial: initial) else { return }
        tui.pager(title: "Routing · \(name)", body: runSelf(["vm", "routing", modes[sel], id]))
    }

    /// Soft/hard reboot from the menu (works on detached remote sessions).
    private func rebootWorkspace(id: String, name: String) {
        guard let sel = tui.menu(
            title: "Reboot \(name)?",
            items: ["Soft reboot (graceful halt)", "Hard reboot (immediate)", "Cancel"],
            footer: "Enter select · q back") else { return }
        switch sel {
        case 0: tui.pager(title: "Reboot \(name)", body: runSelf(["workspaces", "reboot", id]))
        case 1: tui.pager(title: "Reboot \(name)", body: runSelf(["workspaces", "reboot", id, "--hard"]))
        default: return
        }
    }

    /// Flip Fusion for a running workspace via the same `fusion` CLI verb the
    /// menu mirrors elsewhere.
    private func toggleFusion(id: String, name: String, currentlyOn: Bool) {
        let action = currentlyOn ? "disable" : "enable"
        tui.pager(title: "Fusion \(action) · \(name)", body: runSelf(["fusion", action, id]))
    }

    /// Boot an off/suspended workspace window-less, then hand the remote terminal
    /// straight to its tmux — no need to bounce back through the list.
    private func startWorkspace(id: String, name: String) {
        let out = runSelf(["vm", "run", id, "--detach"])
        // The VM id equals the workspace id once booted. Confirm it actually came
        // up before attaching — boot can be refused (e.g. a model still
        // downloading), in which case `out` carries the reason.
        let up = fetchProfiles().contains {
            ($0["id"] as? String) == id &&
            (($0["state"] as? String) == "running" || ($0["state"] as? String) == "booting")
        }
        guard up else { tui.pager(title: "Start \(name)", body: out); return }
        // Fresh boot: wait for the guest's `bromure` tmux session before handing
        // the terminal over, otherwise `tmux attach` races the agent's setup.
        waitForTmux(vmID: id)
        attach(vmID: id, name: name)
    }

    /// Poll the guest until its `bromure` tmux session exists (or we give up).
    private func waitForTmux(vmID: String) {
        for _ in 0..<100 {   // up to ~20s
            let resp = try? client.request(
                "POST", "/vms/\(ControlClient.encodeSegment(vmID))/exec",
                body: ["command": "tmux has-session -t bromure", "timeout": 5])
            if resp?.status == 200, (resp?.json["exitCode"] as? Int ?? 1) == 0 { return }
            usleep(200_000)
        }
    }

    /// Pick what to attach to in a running workspace: a tmux tab (session) or a
    /// running docker container. Loops so detaching returns here, not the top.
    private func attachMenu(vmID: String, name: String) {
        while true {
            let tabs = (fetchVM(vmID)?["tabs"] as? [[String: Any]]) ?? []
            let containers = runningContainers(vmID: vmID)
            // Nothing to choose from yet → just hand over the current tmux tab.
            if tabs.isEmpty && containers.isEmpty { attach(vmID: vmID, name: name); return }

            var labels: [String] = []
            var actions: [() -> Void] = []
            for t in tabs {
                let idx = t["index"] as? Int ?? 0
                let title = t["title"] as? String ?? "shell"
                let active = (t["active"] as? Bool ?? false) ? " *" : ""
                // Worktree tabs read as branches, indented under their parent —
                // parity with the GUI source list's nesting.
                let isWt = t["isWorktree"] as? Bool ?? false
                let indent = String(repeating: "  ", count: Self.worktreeDepth(t, in: tabs))
                let marker = isWt ? "🌿 " : ""
                labels.append("\(indent)\(marker)Tab \(idx): \(title)\(active)")
                actions.append { self.attach(vmID: vmID, name: name, tab: idx) }
            }
            for c in containers {
                labels.append("🐳 \(c.name)  (\(c.image))")
                actions.append { self.attachContainer(vmID: vmID, container: c.name) }
            }
            labels.append("Back")

            guard let sel = tui.menu(title: "Attach · \(name)", items: labels,
                                     footer: "Enter attach · q back") else { return }
            if sel >= 0, sel < actions.count { actions[sel]() } else { return }
        }
    }

    // MARK: - Worktrees (SSH parity with the GUI right-click menu)

    /// Nesting depth of a tab in the worktree tree (0 for ordinary tabs), by
    /// following `parentBranch` → an ancestor tab's `worktreeBranch`. Mirrors
    /// the GUI's `worktreeDepth`, over the API's tab dicts.
    static func worktreeDepth(_ tab: [String: Any], in tabs: [[String: Any]]) -> Int {
        guard tab["isWorktree"] as? Bool == true else { return 0 }
        var depth = 1
        var parent = tab["parentBranch"] as? String
        var guardCount = 0
        while let pb = parent, !pb.isEmpty, guardCount < 8 {
            guard let p = tabs.first(where: { $0["worktreeBranch"] as? String == pb }) else { break }
            depth += 1
            parent = p["parentBranch"] as? String
            guardCount += 1
        }
        return min(depth, 6)
    }

    /// POST a worktree action to the app for `vmID`. Returns true on success.
    @discardableResult
    private func postWorktree(vmID: String, action: String, args: [String]) -> Bool {
        let body: [String: Any] = ["action": action, "args": args]
        let resp = try? client.request(
            "POST", "/sessions/\(ControlClient.encodeSegment(vmID))/worktree", body: body)
        return (resp?.json["ok"] as? Bool) ?? false
    }

    /// Tab command for a running workspace — SSH parity with the GUI's ⌘T /
    /// tab switch. `action` ∈ new/select/close; `index` is the tmux window.
    @discardableResult
    private func postTab(vmID: String, action: String, index: Int = 0) -> Bool {
        let resp = try? client.request(
            "POST", "/sessions/\(ControlClient.encodeSegment(vmID))/tab",
            body: ["action": action, "index": index])
        return (resp?.json["ok"] as? Bool) ?? false
    }
    @discardableResult
    private func postNewTab(vmID: String) -> Bool { postTab(vmID: vmID, action: "new") }

    /// Manage this workspace's worktrees: list repo/worktree/merge tabs, each
    /// with its available actions. Loops so an action returns here.
    private func worktreeMenu(vmID: String, name: String) {
        while true {
            let tabs = (fetchVM(vmID)?["tabs"] as? [[String: Any]]) ?? []
            let tool = fetchVM(vmID)?["tool"] as? String ?? "claude"
            var labels: [String] = []
            var actions: [() -> Void] = []
            for t in tabs {
                let title = t["title"] as? String ?? "shell"
                let indent = String(repeating: "  ", count: Self.worktreeDepth(t, in: tabs))
                if t["isWorktree"] as? Bool == true {
                    labels.append("\(indent)🌿 \(title)")
                    actions.append { self.worktreeTabActions(vmID: vmID, name: name, tab: t, tabs: tabs, tool: tool) }
                } else if t["isMergeTab"] as? Bool == true {
                    labels.append("\(indent)⇗ \(title)")
                    actions.append {
                        guard let dir = t["cwd"] as? String else { return }
                        if self.postWorktree(vmID: vmID, action: "resolve", args: [dir, tool]) {
                            self.tui.toast("Spawning \(tool) to resolve conflicts…")
                        }
                    }
                } else if t["isGitRepo"] as? Bool == true {
                    labels.append("\(indent)＋ New worktree from \(title)…")
                    actions.append { self.createWorktreeRemote(vmID: vmID, tab: t, defaultTool: tool) }
                }
            }
            if labels.isEmpty {
                _ = tui.menu(title: "Worktrees · \(name)", items: ["Back"],
                             footer: "Enter back",
                             header: ["No git repo open in this workspace yet.",
                                      "Open a repo in a tab (cd into it), then it'll appear",
                                      "here as “New worktree from …”."])
                return
            }
            labels.append("Back")
            guard let sel = tui.menu(title: "Worktrees · \(name)", items: labels,
                                     footer: "Enter select · q back",
                                     header: ["＋ New worktree from … → branch a repo into its own tab.",
                                              "🌿 an existing worktree → merge / discard / branch further."]) else { return }
            if sel >= 0, sel < actions.count { actions[sel]() } else { return }
        }
    }

    /// "New worktree" over SSH: task name → tool → optional prompt → create.
    private func createWorktreeRemote(vmID: String, tab: [String: Any], defaultTool: String) {
        guard let cwd = tab["cwd"] as? String else { return }
        guard let rawName = tui.prompt("Task name (e.g. Website refactoring)"),
              !rawName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let taskName = rawName.trimmingCharacters(in: .whitespaces)
        let tools = ["claude", "codex", "grok"]
        let initial = tools.firstIndex(of: defaultTool) ?? 0
        guard let ti = tui.menu(title: "Tool for the worktree", items: tools, initial: initial) else { return }
        let tool = tools[ti]
        let prompt = tui.prompt("Initial prompt (optional)") ?? ""
        let slug = Self.slug(taskName)
        let display = "\(taskName) (\(tool))"
        if postWorktree(vmID: vmID, action: "create", args: [cwd, slug, display, tool, prompt]) {
            tui.toast("Creating worktree “\(taskName)”…")
        } else {
            tui.toast("Couldn't create the worktree.")
        }
    }

    /// Actions on an existing worktree tab: merge (destination pick) or discard.
    private func worktreeTabActions(vmID: String, name: String, tab: [String: Any],
                                    tabs: [[String: Any]], tool: String) {
        let title = tab["title"] as? String ?? "worktree"
        guard let branch = tab["worktreeBranch"] as? String,
              let mainRoot = tab["rootRepo"] as? String else { return }
        var items = ["＋ New worktree from here…", "Merge…", "Discard worktree"]
        if tab["isMergeTab"] as? Bool == true { items.insert("Resolve conflicts", at: 0) }
        items.append("Back")
        guard let sel = tui.menu(title: "Worktree: \(title)", items: items,
                                 footer: "Enter select · q back") else { return }
        let choice = items[sel]
        switch choice {
        case "＋ New worktree from here…":
            // Worktrees off worktrees (nested) — parity with the GUI.
            createWorktreeRemote(vmID: vmID, tab: tab, defaultTool: tool)
        case "Resolve conflicts":
            if let dir = tab["cwd"] as? String {
                _ = postWorktree(vmID: vmID, action: "resolve", args: [dir, tool])
            }
        case "Merge…":
            // Ancestor chain: parentBranch → … → repo root (same as the GUI).
            var chain: [(branch: String, label: String)] = []
            var parent = tab["parentBranch"] as? String
            var guardCount = 0
            while let pb = parent, !pb.isEmpty, guardCount < 8 {
                if let p = tabs.first(where: { $0["worktreeBranch"] as? String == pb }) {
                    chain.append((pb, p["title"] as? String ?? pb))
                    parent = p["parentBranch"] as? String
                } else {
                    chain.append((pb, "\(pb) (repo root)"))
                    break
                }
                guardCount += 1
            }
            guard !chain.isEmpty else { return }
            let dests = chain.enumerated().map { i, d in
                i == 0 ? d.label : "\(d.label)  ⚠︎ skips intermediates"
            }
            guard let di = tui.menu(title: "Merge “\(title)” into", items: dests,
                                    footer: "Enter merge · q cancel") else { return }
            _ = postWorktree(vmID: vmID, action: "merge",
                             args: [branch, chain[di].branch, mainRoot, title, tool])
            tui.toast("Merging into \(chain[di].label)…")
        case "Discard worktree":
            guard tui.confirm("Discard “\(title)”? Removes the checkout and deletes \(branch). Unmerged commits are lost.") else { return }
            _ = postWorktree(vmID: vmID, action: "remove", args: [mainRoot, branch])
            tui.toast("Discarded \(title).")
        default:
            return
        }
    }

    /// Slugify a task name to a branch/dir-safe token (mirrors the GUI).
    static func slug(_ name: String) -> String {
        var out = ""; var lastDash = false
        for ch in name.lowercased() {
            if ch.isLetter || ch.isNumber { out.append(ch); lastDash = false }
            else if !lastDash { out.append("-"); lastDash = true }
        }
        let trimmed = String(out.drop(while: { $0 == "-" }).prefix(40))
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "worktree" : trimmed
    }

    /// docker exec -it into a running container, à la `vm attach … containers:…`.
    private func attachContainer(vmID: String, container: String) {
        // Ask which shell to run rather than hardcoding one — bash often isn't
        // in the image (alpine/distroless), so the default is sh. Escape cancels;
        // a blank entry uses sh. The value is interpolated into the guest
        // `docker exec` line, so restrict it to a safe charset (fall back to sh).
        let allowed = Set(
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/_-.")
        guard let raw = tui.prompt("Shell to run in \(container)  (Enter for sh)") else { return }
        let entered = raw.trimmingCharacters(in: .whitespaces)
        let shell = (!entered.isEmpty && entered.allSatisfy(allowed.contains)) ? entered : "sh"

        tui.end()
        defer { tui.begin() }
        let banner = "\u{1B}[2J\u{1B}[H" +
            "\u{1B}[1m  Type `exit` (or Ctrl-d) to leave the container\u{1B}[0m\r\n\r\n" +
            "  Attaching to \(container) (\(shell))…\r\n"
        FileHandle.standardOutput.write(Data(banner.utf8))
        Thread.sleep(forTimeInterval: 1.0)
        do {
            try InteractiveExec.run(client: client, vm: vmID,
                                    command: "docker exec -it \(container) \(shell)")
        } catch {
            let msg = "\r\nCouldn't attach: \(error.localizedDescription)\r\nPress Enter…"
            FileHandle.standardOutput.write(Data(msg.utf8))
            _ = readLine()
        }
    }

    /// Hand the terminal over to the guest's tmux. Prints the required banner,
    /// then `InteractiveExec` takes over STDIN/STDOUT (its own raw mode) until
    /// the user detaches with Ctrl-b d, at which point we redraw the menu. The
    /// magic keychord (`overlayTrigger`) is caught host-side by InteractiveExec
    /// and pops the controller overlay without the guest seeing it.
    private func attach(vmID: String, name: String, tab: Int? = nil) {
        tui.end()                       // leave alt-screen/raw before handing off
        defer { tui.begin() }
        // Banner — shown during the attach handshake, before tmux repaints.
        let banner = "\u{1B}[2J\u{1B}[H" +
            "\u{1B}[1m  \(Self.chordLabel(overlayTrigger)): workspace menu"
            + "  ·  Ctrl-b d: disconnect\u{1B}[0m\r\n\r\n" +
            "  Attaching…\r\n"
        FileHandle.standardOutput.write(Data(banner.utf8))
        Thread.sleep(forTimeInterval: 1.5)
        var cmd = "tmux attach -t bromure"
        if let tab { cmd += " \\; select-window -t bromure:\(tab)" }
        do {
            try InteractiveExec.run(
                client: client, vm: vmID, command: cmd,
                overlayTrigger: overlayTrigger,
                onOverlay: { [weak self] in self?.remoteOverlay(vmID: vmID, name: name) ?? [] })
        } catch {
            let msg = "\r\nCouldn't attach: \(error.localizedDescription)\r\nPress Enter…"
            FileHandle.standardOutput.write(Data(msg.utf8))
            _ = readLine()
        }
    }

    // MARK: - Controller overlay (the magic keychord target)

    /// Drawn host-side when the user presses the magic keychord while attached
    /// to a workspace's tmux. The guest is paused — nothing here runs in the VM;
    /// every action talks to the app over the control socket. Returns to resume
    /// the tmux attach (InteractiveExec repaints the guest afterwards).
    /// Returns bytes to forward to the guest when the overlay closes — `[]` to
    /// resume the attach, or Ctrl-b d (`[0x02, 0x64]`) to detach ("Disconnect").
    private func remoteOverlay(vmID: String, name: String) -> [UInt8] {
        tui.begin()
        defer { tui.end() }
        var forward: [UInt8] = []
        while true {
            let vm = fetchVM(vmID)
            let tabs = (vm?["tabs"] as? [[String: Any]]) ?? []
            let fusionConfigurable = vm?["fusionConfigurable"] as? Bool ?? false
            let fusionEngaged = vm?["fusionEngaged"] as? Bool ?? false
            let routing = vm?["routing"] as? String ?? "cloud"
            var labels: [String] = []
            var actions: [() -> Bool] = []       // return true → close the overlay (resume the attach)

            // The tab tree — names + worktree nesting — as SWITCHABLE items.
            // Selecting a tab makes it active and closes the overlay, so the
            // guest repaints on that tab. (▸ = current · 📁 repo · 🌿 worktree · ⇗ merge)
            for t in tabs {
                let title = t["title"] as? String ?? "shell"
                let indent = String(repeating: "  ", count: Self.worktreeDepth(t, in: tabs))
                let isActive = (t["active"] as? Bool == true)
                let glyph: String
                if t["isWorktree"] as? Bool == true { glyph = "🌿 " }
                else if t["isMergeTab"] as? Bool == true { glyph = "⇗ " }
                else if t["isGitRepo"] as? Bool == true { glyph = "📁 " }
                else { glyph = "· " }
                let idx = t["index"] as? Int ?? 0
                labels.append("\(isActive ? "▸ " : "  ")\(indent)\(glyph)\(title)")
                actions.append {
                    if !isActive {
                        _ = self.postTab(vmID: vmID, action: "select", index: idx)
                        Thread.sleep(forTimeInterval: 0.35)   // let the guest switch before we repaint
                    }
                    return true                                // close overlay → show the tab
                }
            }
            labels.append("＋ New tab")
            actions.append {
                _ = self.postNewTab(vmID: vmID)
                Thread.sleep(forTimeInterval: 0.35)            // let the new window open + become active
                return true                                    // close overlay → tmux follows to it
            }
            if !tabs.isEmpty {
                labels.append("─────────────")
                actions.append { false }
            }

            labels.append("🌿 Worktrees…")
            actions.append { self.worktreeMenu(vmID: vmID, name: name); return false }
            if fusionConfigurable {
                labels.append("⚡ Fusion: \(fusionEngaged ? "on ✓" : "off")")
                actions.append { self.toggleFusion(id: vmID, name: name, currentlyOn: fusionEngaged); return false }
            }
            labels.append("⇄ Routing: \(routing)")
            actions.append { self.chooseRouting(id: vmID, name: name, current: routing); return false }
            labels.append("✎ Edit settings…")
            actions.append { self.configureWorkspace(id: vmID, name: name); return false }
            labels.append("⟳ Reboot…")
            actions.append { self.rebootWorkspace(id: vmID, name: name); return false }
            labels.append("⏸ Suspend")
            actions.append {
                guard self.tui.confirm("Suspend \(name)? (ends this session)") else { return false }
                _ = self.runSelf(["vm", "kill", vmID, "--suspend"]); return true
            }
            labels.append("⏏ Disconnect")
            actions.append { forward = [0x02, 0x64]; return true }   // Ctrl-b d → tmux detaches, ends the attach
            labels.append("↩ Resume session")
            guard let sel = tui.menu(title: "bromure · \(name)", items: labels,
                                     footer: "Enter switch/select · q resume",
                                     header: vmDashboardLines(vm)) else { return forward }
            if sel >= 0, sel < actions.count {
                if actions[sel]() { return forward }
            } else { return forward }
        }
    }

    // MARK: - Models / Trace

    private func modelsMenu() {
        guard let sel = tui.menu(title: "Models",
                                 items: ["Installed (ls)", "Catalog", "Back"],
                                 footer: "Enter select · q back") else { return }
        switch sel {
        case 0: showOutput("model ls", ["model", "ls"])
        // --all: the TUI has no flag to type, so show the whole catalog (FIT
        // badges mark what fits) — nothing hidden, so the CLI's "use --all" hint
        // is suppressed too.
        case 1: showOutput("model catalog", ["model", "catalog", "--all"])
        default: return
        }
    }

    private func traceMenu() {
        while true {
            guard let sel = tui.menu(title: "Trace",
                                     items: ["Summary", "Hostnames", "Leaks", "Recent (ls)", "Clear", "Back"],
                                     footer: "Enter select · q back") else { return }
            switch sel {
            case 0: showOutput("trace summary", ["trace", "summary"])
            case 1: showOutput("trace hostnames", ["trace", "hostnames"])
            case 2: showOutput("trace leaks", ["trace", "leaks"])
            case 3: showOutput("trace ls", ["trace", "ls"])
            case 4:
                guard tui.confirm("Clear all trace history?") else { break }
                showOutput("trace clear", ["trace", "clear", "--force"])
            default: return
            }
        }
    }

    // MARK: - Data helpers

    private func fetchProfiles() -> [[String: Any]] {
        guard client.isAgentRunning(),
              let ps = try? client.request("GET", "/profiles").json["profiles"] as? [[String: Any]]
        else { return [] }
        return ps.sorted { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }
    }

    /// The running-VM record (carries `tabs`) for a workspace id.
    private func fetchVM(_ id: String) -> [String: Any]? {
        guard let vms = try? client.request("GET", "/vms").json["vms"] as? [[String: Any]]
        else { return nil }
        return vms.first { ($0["id"] as? String) == id }
    }

    /// Running docker containers in a VM, via `docker ps` over the exec bridge.
    private func runningContainers(vmID: String) -> [(name: String, image: String, status: String)] {
        guard let r = try? client.request(
            "POST", "/vms/\(ControlClient.encodeSegment(vmID))/exec",
            body: ["command": "docker ps --format '{{.Names}}\\t{{.Image}}\\t{{.Status}}' 2>/dev/null",
                   "timeout": 5]),
            r.status == 200, let out = r.json["stdout"] as? String else { return [] }
        return out.split(whereSeparator: \.isNewline).compactMap { line in
            let c = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard c.count >= 2 else { return nil }
            return (name: String(c[0]), image: String(c[1]),
                    status: c.count >= 3 ? String(c[2]) : "")
        }
    }

    /// A list row: name, tool, and a glyph for the live state — the same
    /// off/suspended/booting/running vocabulary as the app's unified window.
    private func workspaceLabel(_ ws: [String: Any]) -> String {
        let name = ws["name"] as? String ?? "?"
        let tool = ws["tool"] as? String ?? ""
        let mark: String
        switch ws["state"] as? String ?? "off" {
        case "running":   mark = "● running"
        case "booting":   mark = "◌ booting"
        case "suspended": mark = "⏸ suspended"
        default:          mark = "○ off"
        }
        return "\(pad(name, 22)) \(pad(tool, 7))  \(mark)"
    }

    private func pad(_ s: String, _ w: Int) -> String {
        s.count >= w ? s : s + String(repeating: " ", count: w - s.count)
    }

    /// A compact text version of the GUI workspace dashboard — live CPU / memory
    /// / load, the machine spec, disk, uptime, and a config line. Rendered above
    /// the action menu for a running workspace.
    private func vmDashboardLines(_ vm: [String: Any]?) -> [String] {
        guard let vm else { return ["vitals unavailable"] }
        let hasStats = vm["hasStats"] as? Bool ?? false
        let memUsedKB = vm["memUsedKB"] as? Int ?? 0
        let memTotalKB = vm["memTotalKB"] as? Int ?? 0
        let vcpu = vm["cpuCount"] as? Int ?? 0
        let memGB = vm["memoryGB"] as? Int ?? 0
        let diskBytes = vm["diskAllocatedBytes"] as? Int ?? 0
        let up = vm["uptimeSeconds"] as? Int ?? 0
        let ip = (vm["ip"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "—"
        let tool = vm["tool"] as? String ?? "?"
        let fusionConfigurable = vm["fusionConfigurable"] as? Bool ?? false
        let fusion = (vm["fusionEngaged"] as? Bool ?? false) ? "on" : "off"

        let cpuStr = hasStats ? String(format: "%.0f%%", num(vm["cpu"])) : "—"
        let totGB = memTotalKB > 0 ? Double(memTotalKB) / 1_048_576 : Double(memGB)
        let memStr = (hasStats && memUsedKB > 0)
            ? String(format: "%.1f/%.1f GB", Double(memUsedKB) / 1_048_576, totGB)
            : "\(memGB) GB"
        let loadStr = hasStats ? String(format: "%.2f", num(vm["load"])) : "—"
        // Prefer the guest's df numbers (FS truth) over the host-side CoW
        // clone allocation, which overstates — same rule as the GUI dashboard.
        let dUsedKB = vm["diskUsedKB"] as? Int ?? 0
        let dTotalKB = vm["diskTotalKB"] as? Int ?? 0
        let diskStr = dTotalKB > 0
            ? String(format: "%.1f/%.1f GB", Double(dUsedKB) / 1_048_576, Double(dTotalKB) / 1_048_576)
            : (diskBytes > 0 ? gbFromBytes(diskBytes) : "—")

        var cfg = "IP \(ip)   tool \(tool)"
        if fusionConfigurable { cfg += "   fusion \(fusion)" }
        var lines = [
            "CPU \(pad(cpuStr, 5)) Mem \(pad(memStr, 13)) load \(loadStr)",
            "vCPU \(pad("\(vcpu)", 3)) Disk \(pad(diskStr, 9)) up \(uptimeText(up))",
            cfg,
        ]
        // Externally-reachable listening ports (loopback-bound ones are only
        // visible inside the VM, so they're hidden here — same as the app's
        // dashboard). Deduped across the v4/v6 wildcard pair.
        if let raw = vm["listeningPorts"] as? [[String: Any]] {
            var seen = Set<String>()
            let ports = raw.compactMap { d -> String? in
                guard let port = d["port"] as? Int,
                      let proto = d["proto"] as? String,
                      let addr = d["addr"] as? String else { return nil }
                if addr.hasPrefix("127.") || addr == "[::1]" || addr == "::1" { return nil }
                let label = "\(port)/\(proto)"
                return seen.insert(label).inserted ? label : nil
            }
            if !ports.isEmpty { lines.append("ports \(ports.joined(separator: " "))") }
        }
        return lines
    }

    private func num(_ v: Any?) -> Double {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        return 0
    }
    private func gbFromBytes(_ b: Int) -> String {
        let g = Double(b) / 1_073_741_824
        return g >= 1 ? String(format: "%.1f GB", g)
                      : String(format: "%.0f MB", Double(b) / 1_048_576)
    }
    private func uptimeText(_ secs: Int) -> String {
        let h = secs / 3600, m = (secs % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m" }
        return "\(secs)s"
    }

    /// Run a non-interactive `bromure-ac` subcommand and show its output in the
    /// pager — guaranteeing the menu mirrors the CLI exactly.
    private func showOutput(_ title: String, _ args: [String]) {
        tui.pager(title: title, body: runSelf(args))
    }

    private func runSelf(_ args: [String]) -> String {
        let exe = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return "Error: \(error.localizedDescription)" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Run a `bromure-ac` subcommand attached to THIS terminal (inherited
    /// stdio) so long-running commands draw live progress — e.g. `model pull`
    /// from the settings model dropdown. Caller must `tui.end()` before and
    /// `tui.begin()` after. Returns the exit status.
    private func runSelfInteractive(_ args: [String]) -> Int32 {
        let exe = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}
