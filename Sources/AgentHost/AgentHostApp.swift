import AppKit
import ServiceManagement
import Sparkle

/// The menu-bar app: starts tmux, the control socket and the SSH server, and
/// shows what's running. Quitting leaves the agents running in tmux; the
/// next launch picks them up again.
@MainActor
final class AgentHostApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var sshError: String?
    private var refreshTimer: Timer?
    private var iconNeedsYou = false
    /// Sparkle, in release builds only (see startUpdater).
    private var updater: SPUStandardUpdaterController?
    private let updateReminders = GentleUpdateReminders()

    static let portKey = "sshPort"
    static let defaultPort = 2223
    private var port: Int {
        let p = UserDefaults.standard.integer(forKey: Self.portKey)
        return p > 0 ? p : Self.defaultPort
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AgentHostPaths.ensure()
        UserDefaults.standard.removeObject(forKey: "passwordAuth")   // the retired password sign-in
        HostEnvironment.writeShims()
        HostEnvironment.captureLoginPath()
        ClaudeHooks.writeSettings()
        Tmux.ensureServer()
        do { try ControlServer.shared.start() } catch {
            AgentHostLog.log("control: \(error)")
        }
        SessionEngine.shared.startBranchLoop()
        do { try DelegationHub.shared.start() } catch {
            AgentHostLog.log("delegation: \(error)")
        }
        // A connected Bromure AC parks its delegation-MCP channels here.
        RemoteAccessServer.shared.delegationMCPResolver = { offer in DelegationHub.shared.park(offer) }
        startSSH()
        P2PAccount.shared.start(sshPort: port)
        MachineLinker.shared.resume()
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleURL(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = SidecarMark.menuBarImage(badge: false)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        NotificationCenter.default.addObserver(forName: SessionEngine.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateIcon() }
        }
        // Keep the icon's "needs you" badge current while nobody polls.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            DispatchQueue.global().async {
                _ = SessionEngine.shared.snapshot()
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.updateIcon() } }
            }
        }
        startUpdater()
        openAtLoginOnFirstLaunch()
        AgentsWindowController.shared.showIntroIfNeeded()
        AgentHostLog.log("Bromure Sidecar up (tmux \(Tmux.binary), ssh port \(port))")
    }

    // MARK: Updates and login

    /// Sparkle checks the Sidecar channel daily. Only a Developer ID build
    /// updates itself: a dev build (ad-hoc signed, run from .build) would
    /// otherwise be replaced by the latest release.
    private func startUpdater() {
        guard Self.isDeveloperIDSigned else {
            AgentHostLog.log("updates: off (not a Developer ID build)")
            return
        }
        updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil,
                                               userDriverDelegate: updateReminders)
    }

    static let isDeveloperIDSigned: Bool = {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code) == errSecSuccess,
              let code else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return false }
        return dict[kSecCodeInfoTeamIdentifier as String] != nil
    }()

    /// Sidecar is how a Mac's agents stay reachable: it opens at login from
    /// the first launch on. The menu's "Open at Login" turns it off.
    private func openAtLoginOnFirstLaunch() {
        let key = "login.defaulted"
        guard !UserDefaults.standard.bool(forKey: key), Bundle.main.bundleURL.pathExtension == "app" else { return }
        UserDefaults.standard.set(true, forKey: key)
        do { try SMAppService.mainApp.register() } catch {
            AgentHostLog.log("login: couldn't register (\(error.localizedDescription))")
        }
    }

    @objc private func checkForUpdates(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        updater?.checkForUpdates(sender)
    }

    private func startSSH() {
        do {
            // Loopback only: devices come in through the bromure.io relay,
            // which this Mac dials out to (P2PAccount). No inbound port.
            // Keys only: the account's devices (synced from bromure.io) are
            // the only way in — never the Mac account's password.
            try RemoteAccessServer.shared.start(.init(port: port, bindAddress: "127.0.0.1",
                                                      passwordAuth: false))
            sshError = nil
        } catch {
            sshError = error.localizedDescription
            AgentHostLog.log("ssh: \(error.localizedDescription)")
        }
    }

    private func updateIcon() {
        let snap = SessionEngine.shared.snapshot()
        let needsYou = snap.windows.contains {
            snap.agents[$0.index] != nil && ($0.status == "needsInput" || snap.prompting.contains($0.index))
        }
        guard needsYou != iconNeedsYou || statusItem.button?.image == nil else { return }
        iconNeedsYou = needsYou
        statusItem.button?.image = SidecarMark.menuBarImage(badge: needsYou)
        statusItem.button?.setAccessibilityLabel(needsYou ? "Bromure Sidecar — an agent needs you" : "Bromure Sidecar")
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let account = P2PAccount.shared
        let linker = MachineLinker.shared

        let header = NSMenuItem()
        header.view = SidecarMenuHeader.view(status: connectionStatus(account: account, linker: linker))
        menu.addItem(header)
        menu.addItem(.separator())

        // Sessions
        menu.addItem(section("Sessions"))
        let snap = SessionEngine.shared.snapshot()
        let live = snap.sessions.filter { $0.windowIndex != nil && $0.deletedAt == nil }
        if live.isEmpty { menu.addItem(disabled("No agents running")) }
        for s in live {
            let w = snap.windows.first { $0.index == s.windowIndex }
            let status: String
            switch (snap.agents[s.windowIndex ?? -1] != nil, w?.status) {
            case (false, _): status = s.launchingSince != nil ? "Starting" : "Exited"
            case (true, "working"): status = "Working"
            case (true, "needsInput"): status = "Needs you"
            case (true, _) where snap.prompting.contains(s.windowIndex ?? -1): status = "Needs you"
            default: status = "Idle"
            }
            let agent = AgentSpec.spec(s.tool)
            let item = labeled(s.title, detail: "\(agent?.name ?? s.tool) · \(status)")
            item.image = agent?.logo.map { SidecarMark.sized($0, height: 15) }
            let sub = NSMenu()
            let open = NSMenuItem(title: "Open in Terminal", action: #selector(openInTerminal(_:)), keyEquivalent: "")
            open.representedObject = s.windowIndex
            open.target = self
            open.image = symbol("terminal")
            sub.addItem(open)
            let end = NSMenuItem(title: "End Session", action: #selector(endSession(_:)), keyEquivalent: "")
            end.representedObject = s.id
            end.target = self
            end.image = symbol("xmark.circle")
            sub.addItem(end)
            item.submenu = sub
            menu.addItem(item)
        }
        menu.addItem(action("New Claude Session…", #selector(newSession), symbol: "plus.bubble", key: "n"))
        menu.addItem(.separator())

        // Connection
        menu.addItem(section("Connection"))
        if sshError != nil {
            // The header says why; nothing to do here but quit and relaunch.
        } else if account.enrolling {
            menu.addItem(disabled("Waiting for bromure.io…"))
        } else if !account.isEnrolled {
            menu.addItem(action("Sign in to bromure.io…", #selector(signIn), symbol: "person.crop.circle.badge.checkmark"))
            // ⌥: the manual path, when the browser can't hand the link back.
            let paste = action("Paste Enrollment Link…", #selector(pasteLink), symbol: "doc.on.clipboard")
            paste.isAlternate = true
            paste.keyEquivalentModifierMask = .option
            menu.addItem(paste)
        }
        addAttachItems(to: menu, account: account)
        menu.addItem(.separator())

        // Agents
        menu.addItem(action("Manage Agents…", #selector(manageAgents), symbol: "square.and.arrow.down.on.square"))
        menu.addItem(approvalsItem())
        menu.addItem(settingsItem(account: account))
        menu.addItem(.separator())

        if let updater {
            let title = updateReminders.pendingVersion.map { "Install Update (\($0))…" } ?? "Check for Updates…"
            let check = action(title, #selector(checkForUpdates(_:)),
                               symbol: updateReminders.pendingVersion == nil ? "arrow.triangle.2.circlepath" : "arrow.down.circle.fill")
            check.isEnabled = updater.updater.canCheckForUpdates
            menu.addItem(check)
        }
        let quit = labeled("Quit Bromure Sidecar", detail: "Agents keep running")
        quit.action = #selector(NSApplication.terminate(_:))
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    /// The header's one line: where this Mac's agents can be reached from.
    private func connectionStatus(account: P2PAccount, linker: MachineLinker) -> SidecarMenuHeader.Status {
        if let sshError { return .init(text: "Stopped — \(sshError)", tone: .error) }
        if account.enrolling { return .init(text: "Signing in to bromure.io…", tone: .busy) }
        if let t = linker.current {
            if linker.isAwaitingApproval { return .init(text: "Waiting for approval on \(t.label)", tone: .busy) }
            if linker.isLinked { return .init(text: "Attached to \(t.label) as \(ControlServer.machineName)", tone: .good) }
            return .init(text: linker.error.map { "Can't reach \(t.label) — \($0)" } ?? "Attaching to \(t.label)…",
                         tone: linker.error == nil ? .busy : .error)
        }
        if let err = account.lastError { return .init(text: err, tone: .error) }
        return account.isEnrolled ? .init(text: "Not attached to a Bromure AC", tone: .idle)
                                  : .init(text: "Not signed in to bromure.io", tone: .idle)
    }

    private func approvalsItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Agent Approvals", action: nil, keyEquivalent: "")
        item.image = symbol("checkmark.shield")
        let menu = NSMenu()
        for spec in AgentSpec.all {
            let current = AgentApprovals.current(spec.id)
            let detail: String
            switch current {
            case .ask: detail = "Asks before acting"
            case .auto: detail = spec.id == "codex" ? "Never asks · sandboxed" : "Asks only when risky"
            case .full: detail = "Never asks"
            }
            let agent = labeled(spec.name, detail: detail)
            agent.image = spec.logo.map { SidecarMark.sized($0, height: 15) }
            let sub = NSMenu()
            for level in AgentApprovals.levels(spec.id) {
                let choice = NSMenuItem(title: level.title(spec.id), action: #selector(setApprovals(_:)), keyEquivalent: "")
                choice.target = self
                choice.representedObject = [spec.id, level.rawValue]
                choice.state = current == level ? .on : .off
                sub.addItem(choice)
            }
            agent.submenu = sub
            menu.addItem(agent)
        }
        menu.addItem(.separator())
        menu.addItem(disabled("Applies to sessions started or resumed from now on"))
        item.submenu = menu
        return item
    }

    private func settingsItem(account: P2PAccount) -> NSMenuItem {
        let item = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        item.image = symbol("gearshape")
        let menu = NSMenu()
        menu.addItem(action("Rename “\(ControlServer.machineName)”…", #selector(renameMachine), symbol: "pencil"))
        let login = action("Open at Login", #selector(toggleLogin(_:)), symbol: "power")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        let install = action("Install “bromure-claude” Command", #selector(installCommand), symbol: "chevron.left.forwardslash.chevron.right")
        install.toolTip = "Links ~/.local/bin/bromure-claude: run it in any folder to start Claude there as a hosted session."
        menu.addItem(install)
        if sshError == nil, let fp = RemoteAccessServer.shared.hostKeyFingerprint()?.split(separator: " ").dropFirst().first {
            let key = labeled("Copy Host Key Fingerprint", detail: String(fp))
            key.action = #selector(copyFingerprint(_:))
            key.target = self
            key.representedObject = String(fp)
            key.image = symbol("key")
            key.toolTip = "Compare it with what Bromure AC shows when it adds this Mac."
            menu.addItem(key)
        }
        if account.isEnrolled {
            menu.addItem(.separator())
            menu.addItem(action("Sign Out of bromure.io", #selector(signOut), symbol: "rectangle.portrait.and.arrow.right"))
        }
        item.submenu = menu
        return item
    }

    // MARK: Menu items

    private func section(_ title: String) -> NSMenuItem {
        NSMenuItem.sectionHeader(title: title)
    }

    private func action(_ title: String, _ selector: Selector, symbol name: String? = nil, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        if let name { item.image = symbol(name) }
        return item
    }

    /// A title with a quieter second line (a subtitle on macOS 14.4+).
    private func labeled(_ title: String, detail: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        if #available(macOS 14.4, *) {
            item.subtitle = detail
        } else {
            item.title = "\(title) — \(detail)"
        }
        return item
    }

    private func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func copyFingerprint(_ sender: NSMenuItem) {
        guard let fp = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(fp, forType: .string)
    }

    @objc private func openInTerminal(_ sender: NSMenuItem) {
        guard let idx = sender.representedObject as? Int else { return }
        Self.openTerminal(window: idx)
    }

    @objc private func endSession(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        DispatchQueue.global().async { _ = SessionEngine.shared.command(id, "close", [:]) }
    }

    @objc private func newSession() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Start Claude Here"
        panel.message = "Choose the folder Claude works in."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        DispatchQueue.global().async {
            if case .success(let s) = SessionEngine.shared.start(.init(tool: "claude", cwd: url.path)) {
                DispatchQueue.main.async { Self.openTerminal(window: s.window) }
            }
        }
    }

    @objc private func manageAgents() {
        AgentsWindowController.shared.show()
    }

    @objc private func installCommand() {
        let bin = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/bin")
        let link = bin.appendingPathComponent("bromure-claude")
        let alert = NSAlert()
        do {
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: link)
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: AgentHostPaths.stableExecutable)
            alert.messageText = "Installed bromure-claude"
            alert.informativeText = "Run `bromure-claude` in any folder to start Claude there as a session Bromure AC can see. (\(link.path) — make sure ~/.local/bin is on your PATH.)"
        } catch {
            alert.messageText = "Couldn't install bromure-claude"
            alert.informativeText = error.localizedDescription
        }
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: Attaching

    /// Where this Mac's agents show up: attached to a Bromure AC (here, or an
    /// account server), they're one more machine in its lists.
    private func addAttachItems(to menu: NSMenu, account: P2PAccount) {
        let linker = MachineLinker.shared
        let item = NSMenuItem(title: linker.current == nil ? "Attach to Bromure AC" : "Switch Bromure AC", action: nil, keyEquivalent: "")
        item.image = symbol("link")
        let sub = NSMenu()
        if FileManager.default.fileExists(atPath: MachineLinker.localControlSocket) {
            let local = NSMenuItem(title: "Bromure AC on This Mac", action: #selector(attachTo(_:)), keyEquivalent: "")
            local.representedObject = MachineLinker.Target.local
            local.target = self
            local.image = symbol("desktopcomputer")
            local.state = linker.current == .local ? .on : .off
            sub.addItem(local)
        }
        if account.isEnrolled {
            for d in account.servers {
                let t = MachineLinker.Target.device(id: d.id, name: d.name ?? d.id,
                                                    user: d.sshUsername ?? NSUserName())
                let i = NSMenuItem(title: d.name ?? d.id, action: #selector(attachTo(_:)), keyEquivalent: "")
                i.representedObject = t
                i.target = self
                i.image = symbol("server.rack")
                i.state = linker.current == t ? .on : .off
                sub.addItem(i)
            }
            account.refreshServers()
        }
        if sub.items.isEmpty {
            sub.addItem(disabled(account.isEnrolled ? "No Bromure AC online" : "Sign in to bromure.io to see your servers"))
        }
        if linker.current != nil {
            sub.addItem(.separator())
            let d = NSMenuItem(title: "Detach", action: #selector(detach), keyEquivalent: "")
            d.target = self
            sub.addItem(d)
        }
        item.submenu = sub
        menu.addItem(item)
    }

    @objc private func attachTo(_ sender: NSMenuItem) {
        guard let t = sender.representedObject as? MachineLinker.Target else { return }
        MachineLinker.shared.attach(t)
    }

    @objc private func detach() { MachineLinker.shared.detach() }

    /// Registering: name the machine first (it becomes the bromure.io
    /// device's name, and what Bromure AC lists).
    @objc private func signIn() {
        guard askMachineName(title: "Name this machine",
                             message: "This is how it shows up in your Bromure devices and under Native Machines in Bromure AC.",
                             confirm: "Continue") else { return }
        P2PAccount.shared.beginSignIn()
    }

    @objc private func renameMachine() {
        _ = askMachineName(title: "Rename this machine",
                           message: "Bromure AC shows the new name as soon as it reconnects. The name of the device on bromure.io stays what it was at sign-in (rename it in the dashboard).",
                           confirm: "Rename")
    }

    /// Ask for the machine's name (prefilled); saved on confirm.
    private func askMachineName(title: String, message: String, confirm: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = ControlServer.machineName
        field.placeholderString = ControlServer.defaultMachineName
        alert.accessoryView = field
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        ControlServer.setMachineName(field.stringValue)
        AgentHostLog.log("machine name: \(ControlServer.machineName)")
        return true
    }

    @objc private func signOut() { P2PAccount.shared.signOut() }

    @objc private func pasteLink() {
        let alert = NSAlert()
        alert.messageText = "Paste an enrollment link"
        alert.informativeText = "The bromure://enroll… link (or bare code) for this Mac."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.stringValue = NSPasteboard.general.string(forType: .string) ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "Enroll")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        P2PAccount.shared.complete(field.stringValue)
    }

    /// `bromure-agent-host://enroll?…` — bromure.io handing back the code.
    @objc private func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue else { return }
        AgentHostLog.log("url: \(s.prefix(40))…")
        P2PAccount.shared.complete(s)
    }

    @objc private func setApprovals(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2,
              let level = AgentApprovals(rawValue: pair[1]) else { return }
        let tool = pair[0]
        guard level != AgentApprovals.current(tool) else { return }
        let name = AgentSpec.spec(tool)?.name ?? tool
        if level == .full {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Let \(name) run anything without asking?"
            alert.informativeText = "\(name) will run commands on this Mac as you, with no confirmation and no sandbox — nothing like a Bromure VM stands between the agent and your files, keys and accounts. A prompt injection in anything it reads could act with your full access."
            alert.addButton(withTitle: "Never Ask")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        AgentApprovals.set(level, for: tool)
        AgentHostLog.log("approvals: \(tool) set to \(level.rawValue)")
    }

    @objc private func toggleLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            AgentHostLog.log("login item: \(error.localizedDescription)")
        }
    }

    /// Attach Terminal to window `window` through a .command script.
    static func openTerminal(window: Int) {
        let script = FileManager.default.temporaryDirectory
            .appendingPathComponent("bromure-agent-\(window)-\(UUID().uuidString.prefix(6)).command")
        let attach = Tmux.viewAttachCommand(view: "term-\(UUID().uuidString.prefix(8))", window: window, sizePassive: false)
        let body = "#!/bin/sh\nrm -f \(shellQuote(script.path))\n\(attach)\n"
        do {
            try body.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            NSWorkspace.shared.open(script)
        } catch {
            AgentHostLog.log("open terminal: \(error.localizedDescription)")
        }
    }
}

/// A menu-bar app has no window to put a scheduled update in front of the
/// user: Sparkle's gentle reminders, surfaced as the menu's
/// "Install Update (x)…" instead of a window popping up unannounced.
final class GentleUpdateReminders: NSObject, SPUStandardUserDriverDelegate {
    private(set) var pendingVersion: String?

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                              andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                   state: SPUUserUpdateState) {
        if !handleShowingUpdate { pendingVersion = update.displayVersionString }
    }

    func standardUserDriverWillFinishUpdateSession() {
        pendingVersion = nil
    }
}
