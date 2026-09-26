#if os(macOS)
import Foundation
import SandboxEngine

// MARK: - Messaging connector (engine side)
//
// One small managed VM (File › Infrastructure › Messaging Connector…) that
// links the Switchboard to the user's phone and chat. It boots through the
// same path as a registry or a cluster node (`bootMachine` — suspended with
// the app, resumed on relaunch, fsck'd when its disks need it) and runs
// Signal (signal-cli-rest-api) and WhatsApp (GOWA) under docker, and Slack
// over Socket Mode, with a relay turning their messages into an inbox
// (vm-setup/bromure-msgbridge.*).
//
// The host drains that inbox every few seconds over the shell channel and
// lets through only the user: their number (own-number mode), their own
// Note to Self / "Message yourself" chat (linked mode), or — on Slack — a
// direct message from the one Slack account paired with a one-time code.
// Everything else is dropped before the Switchboard could see it. Replies go
// back the same way. The account keys and tokens never leave the VM's data
// disk.

extension KubeClusterEngine {
    static let connectorScriptPath = "/mnt/bromure-meta/bromure-msgbridge.sh"
    /// Every reply the Switchboard sends starts with this — how it reads on
    /// the phone, and how its own echo (linked mode puts replies in the
    /// very chat the user writes in) is told from the user.
    static let connectorReplyMark = "☎️ "

    private func relay(_ connector: MessagingConnector, _ args: [String], timeout: Int = 60) async throws -> [String: Any] {
        let quoted = args.map(Self.shellQuote).joined(separator: " ")
        let raw = try await exec(connector.node.id, "bash \(Self.connectorScriptPath) relay \(quoted)", timeout: timeout)
        let line = raw.split(separator: "\n").last.map(String.init) ?? ""
        guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
            throw KubeError.message("The connector didn't answer (\(raw.prefix(200)))")
        }
        return obj
    }

    private static func b64(_ s: String) -> String { Data(s.utf8).base64EncodedString() }

    // MARK: Lifecycle

    /// The connector — created (and provisioned) the first time it's asked for.
    @discardableResult
    func ensureConnector() -> MessagingConnector {
        if let c = store.connector { return c }
        let c = MessagingConnector()
        store.upsert(c)
        store.setStatus(c.id) { $0 = KubeClusterStatus(); $0.phase = .creating }
        let id = c.id
        runtime(id).lifecycleTask = Task { [weak self] in await self?.provisionConnector(id) }
        return c
    }

    func startConnector(_ id: UUID) {
        guard store.connector(id) != nil else { return }
        let phase = store.status(id).phase
        guard !phase.isBusy, !phase.isUp else { return }
        let rt = runtime(id)
        rt.stopping = false
        store.setStatus(id) { $0.phase = .starting; $0.message = nil; $0.log = []; $0.step = nil }
        rt.lifecycleTask = Task { [weak self] in await self?.provisionConnector(id) }
    }

    func stopConnector(_ id: UUID) async { await stop(id) }

    func restartConnector(_ id: UUID) {
        Task { [weak self] in
            guard let self else { return }
            await self.stopConnector(id)
            self.startConnector(id)
        }
    }

    /// Removes the VM and its disk — and with it the linked accounts.
    func deleteConnector(_ id: UUID) async {
        guard let c = store.connector(id) else { return }
        await stop(id)
        store.setStatus(id) { $0.phase = .deleting }
        MACBindings.shared.release(profileID: c.node.id)
        try? FileManager.default.removeItem(at: clusterDirectory(id))
        runtimes[id] = nil
        watched.remove(id)
        store.removeConnector(id)
    }

    func setConnectorAutoStart(_ id: UUID, _ on: Bool) {
        guard var c = store.connector(id), c.autoStart != on else { return }
        c.autoStart = on
        store.upsert(c)
    }

    private func provisionConnector(_ id: UUID) async {
        guard var c = store.connector(id) else { return }
        let rt = runtime(id)
        let fresh = !c.provisioned
        log(id, fresh ? "Creating the messaging connector" : "Starting the messaging connector…")
        do {
            step(id, "Booting the connector VM")
            try FileManager.default.createDirectory(at: clusterDirectory(id), withIntermediateDirectories: true)
            let ip: String
            if let live = rt.nodes[c.node.id], live.up, let known = live.ip {
                ip = known
            } else {
                ip = try await bootMachine(MachineSpec(
                    ownerID: id, record: c.node, cpus: 2, memoryGB: 1,
                    memoryMB: c.effectiveMemoryMB,
                    dataDiskGB: c.diskGB,
                    comment: "Messaging connector (Signal, WhatsApp, Slack) — managed by Bromure.",
                    scripts: [("bromure-msgbridge.sh", app.connectorScriptURL),
                              ("bromure-msgbridge.py", app.connectorRelayURL)],
                    ipCommand: "bash \(Self.connectorScriptPath) ip",
                    restoreSavedState: c.provisioned), rt: rt)
            }
            c.node.lastIP = ip
            store.upsert(c)
            store.setStatus(id) { $0.nodesUp = 1; $0.address = ip }

            step(id, fresh ? "Installing Signal and WhatsApp" : "Starting Signal and WhatsApp")
            try await runStep(id, node: c.node, step: "setup", args: [], scriptPath: Self.connectorScriptPath)
            c.provisioned = true
            store.upsert(c)
            try? await pushConnectorConfig(c)

            store.setStatus(id) {
                $0.phase = .running
                $0.step = nil
                $0.message = nil
                $0.startedAt = Date()
            }
            startConnectorLoop(id)
            log(id, "✓ Connector running")
        } catch is CancellationError {
            log(id, "Cancelled.")
        } catch {
            fail(id, "\(fresh ? "Creating" : "Starting") the connector failed: \(error.localizedDescription)")
        }
    }

    /// Tell the relay which Signal account to listen on.
    func pushConnectorConfig(_ c: MessagingConnector) async throws {
        var cfg: [String: Any] = [:]
        if let s = c.signal, s.connected, let n = s.account { cfg["signal"] = ["number": n] }
        let data = try JSONSerialization.data(withJSONObject: cfg)
        _ = try await relay(c, ["configure", data.base64EncodedString()])
    }

    // MARK: Inbox + probe

    func startConnectorLoop(_ id: UUID) {
        guard let rt = runtimes[id] else { return }
        rt.probeTask?.cancel()
        rt.probeTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self else { return }
                await self.drainConnector(id)
                if tick % (self.watched.contains(id) ? 2 : 7) == 0 { await self.probeConnectorOnce(id) }
                tick += 1
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    private func probeConnectorOnce(_ id: UUID) async {
        guard let c = store.connector(id), runtimes[id]?.nodes[c.node.id]?.up == true else { return }
        guard let out = try? await exec(c.node.id, "bash \(Self.connectorScriptPath) probe", timeout: 30),
              let info = MessagingConnectorInfo.decode(Data((out.split(separator: "\n").last.map(String.init) ?? "").utf8))
        else {
            store.setStatus(id) { $0.message = "Connector probe failed" }
            return
        }
        store.setStatus(id) {
            $0.connector = info
            if $0.phase == .running {
                if !(info.signalUp && info.whatsappUp) {
                    $0.message = "A messaging service isn't answering"
                } else if c.slack?.connected == true, info.slackConnected == false {
                    $0.message = "Slack isn't connected" + (info.slackError.map { " (\($0))" } ?? "")
                } else {
                    $0.message = nil
                }
            }
        }
    }

    private func drainConnector(_ id: UUID) async {
        guard let c = store.connector(id), runtimes[id]?.nodes[c.node.id]?.up == true,
              let out = try? await relay(c, ["drain"], timeout: 20),
              let items = out["messages"] as? [[String: Any]], !items.isEmpty else { return }
        for item in items {
            guard let text = (item["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { continue }
            let kind = ConnectorChannel.Kind(rawValue: item["channel"] as? String ?? "")
            if kind == .slack, await slackPairingMessage(item, text: text) { continue }
            guard let kind, let channel = store.connector?.channel(kind), channel.connected else { continue }
            guard Self.isFromUser(item, channel: channel) else {
                // Enough to tell a misrecognized self-chat from a stranger,
                // no message content.
                log(id, "Ignored a \(kind.displayName) message not from you "
                    + "(chat \(Self.redacted(item["chat"] as? String)), from \(Self.redacted(item["from"] as? String)), "
                    + (kind == .slack
                       ? "\(item["channelType"] as? String ?? "?")\((item["bot"] as? Bool) == true ? ", bot" : ""))"
                       : "fromMe \((item["fromMe"] as? Bool) ?? false))"))
                continue
            }
            if text.hasPrefix(Self.connectorReplyMark.trimmingCharacters(in: .whitespaces))
                || connectorEchoes.contains(Self.echoKey(text)) { continue }
            log(id, "Message from the user on \(kind.displayName)")
            onConnectorMessage?(kind, text)
        }
    }

    /// A Slack DM carrying the pairing code, while pairing is under way:
    /// its sender becomes the one Slack account Bromure answers. True when
    /// the item was the pairing (it never reaches the Switchboard).
    private func slackPairingMessage(_ item: [String: Any], text: String) async -> Bool {
        guard let pairing = slackPairing, var c = store.connector, var ch = c.slack else { return false }
        guard Date() < pairing.until else { slackPairing = nil; return false }
        let words = text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined()
        guard words == pairing.code.lowercased() else {
            // A DM that isn't the code, while nobody is paired yet: count it —
            // a stream of them is someone guessing, and pairing stops.
            if c.slack?.connected != true, Self.isSlackDirectMessage(item, workspaceID: ch.workspaceID) {
                slackPairingMisses += 1
                if slackPairingMisses >= 10 {
                    slackPairing = nil
                    slackPairingAborted = true
                    log(c.id, "Slack pairing called off: \(slackPairingMisses) direct messages with a wrong code")
                }
            }
            return false
        }
        // The code proves who is on the other end — but only from a person's
        // direct message, in the app's own workspace.
        let from = item["from"] as? String ?? ""
        guard Self.isSlackDirectMessage(item, workspaceID: ch.workspaceID), !from.isEmpty else {
            log(c.id, "Ignored a Slack pairing code that wasn't a direct message from a person")
            return true
        }
        slackPairing = nil
        slackPairingMisses = 0
        ch.allowed = [from]
        ch.connected = true
        c.slack = ch
        store.upsert(c)
        log(c.id, "Slack paired with \(Self.redacted(from))")
        _ = await sendToUser("Paired. I'm your Bromure Switchboard — ask me what's going on.", via: .slack)
        return true
    }

    /// Test hook (control socket): a fake inbound item through the same
    /// user filter and delivery as the real inbox.
    func injectConnectorMessage(_ kind: ConnectorChannel.Kind, _ item: [String: Any]) {
        guard let c = store.connector, let channel = c.channel(kind),
              channel.connected, let text = item["text"] as? String else { return }
        guard Self.isFromUser(item, channel: channel) else {
            log(c.id, "Ignored an injected \(kind.rawValue) message from someone else")
            return
        }
        if text.hasPrefix(Self.connectorReplyMark.trimmingCharacters(in: .whitespaces))
            || connectorEchoes.contains(Self.echoKey(text)) { return }
        log(c.id, "Message from the user on \(kind.displayName) (injected)")
        onConnectorMessage?(kind, text)
    }

    /// Only the user reaches the Switchboard. Own number: a message whose
    /// sender is on the allow-list. Linked: the account writing to itself —
    /// Signal's Note to Self sync, WhatsApp's "Message yourself" chat.
    /// Slack: a direct message from the paired member — never a channel, a
    /// thread elsewhere, a bot, an edit or anyone else in the workspace.
    static func isFromUser(_ item: [String: Any], channel: ConnectorChannel) -> Bool {
        let from = item["from"] as? String ?? ""
        switch (channel.kind, channel.mode) {
        case (.slack, _):
            return isSlackDirectMessage(item, workspaceID: channel.workspaceID)
                && !from.isEmpty && channel.allowed.contains(from)
        case (.signal, .linked):
            return (item["noteToSelf"] as? Bool) == true && from == channel.account
        case (.signal, .ownNumber):
            return channel.allowed.contains(from)
        case (.whatsapp, .linked):
            // The self-chat, however WhatsApp names it: the chat is the
            // sender (by phone JID or by LID), or the account itself. A
            // message the user sent to anyone ELSE is also "from me" — and
            // never reaches the Switchboard.
            guard (item["fromMe"] as? Bool) == true else { return false }
            let chat = item["chat"] as? String ?? ""
            let chatLid = item["chatLid"] as? String ?? ""
            let fromLid = item["fromLid"] as? String ?? ""
            if !digits(chat).isEmpty, digits(chat) == digits(from) { return true }
            if !fromLid.isEmpty, chat == fromLid || chatLid == fromLid { return true }
            if let account = channel.account, !digits(account).isEmpty,
               digits(chat) == digits(account), !chat.hasSuffix("@lid") { return true }
            return false
        case (.whatsapp, .ownNumber):
            return (item["fromMe"] as? Bool) != true && channel.allowed.contains { digits($0) == digits(from) }
        }
    }

    /// A person's plain direct message to the app, in its own workspace: a
    /// DM (not a channel or group), no bot, no subtype (edits, joins, file
    /// shares, "message_changed"… carry one), from the workspace the app
    /// lives in (Slack Connect DMs come from other organizations).
    static func isSlackDirectMessage(_ item: [String: Any], workspaceID: String?) -> Bool {
        guard (item["channelType"] as? String) == "im",
              (item["bot"] as? Bool) != true,
              ((item["subtype"] as? String) ?? "").isEmpty else { return false }
        if let ws = workspaceID, !ws.isEmpty, let team = item["team"] as? String, !team.isEmpty, team != ws {
            return false
        }
        return true
    }

    /// The phone-number digits of a number or JID ("+1 555…", "1555…@s.whatsapp.net").
    static func digits(_ s: String) -> String {
        let user: Substring = s.split(separator: "@").first ?? Substring(s)
        let bare: Substring = user.split(separator: ":").first ?? user
        return String(bare.filter { $0.isNumber })
    }

    /// "…4567@s.whatsapp.net" — enough to debug a filter, not to read a number.
    static func redacted(_ s: String?) -> String {
        guard let s, !s.isEmpty else { return "-" }
        let parts = s.split(separator: "@", maxSplits: 1)
        let user = String(parts[0])
        let tail = parts.count > 1 ? "@" + parts[1] : ""
        return "…" + String(user.suffix(4)) + tail
    }

    static func echoKey(_ text: String) -> String {
        String(text.lowercased().filter { !$0.isWhitespace }.prefix(200))
    }

    // MARK: Sending

    /// Say `text` to the user on `kind` (or whichever channel is connected).
    /// false when there's none, or the service refused.
    @discardableResult
    func sendToUser(_ text: String, via kind: ConnectorChannel.Kind? = nil) async -> Bool {
        guard let c = store.connector else { return false }
        let channels = c.channels.filter { kind == nil || $0.kind == kind }
        guard let ch = channels.first, let to = ch.replyAddress else { return false }
        let account = ch.account ?? to
        let body = Self.connectorReplyMark + text
        connectorEchoes.insert(Self.echoKey(body))
        connectorEchoes.insert(Self.echoKey(text))
        let args: [String]
        switch ch.kind {
        case .signal:   args = ["signal-send", account, to, Self.b64(body)]
        case .whatsapp: args = ["wa-send", Self.digits(to), Self.b64(body)]
        case .slack:    args = ["slack-send", to, Self.b64(body)]
        }
        guard let r = try? await relay(c, args, timeout: 60), let status = r["status"] as? Int else { return false }
        if !(200..<300).contains(status) {
            log(c.id, "Sending on \(ch.kind.rawValue) failed (HTTP \(status)): \(r["result"] ?? "")")
            return false
        }
        // Logged on success too: in linked mode the reply lands silently in
        // the user's own self-chat, and "did it go out?" is the first question.
        log(c.id, "Sent a message on \(ch.kind.displayName)"
            + (ch.mode == .linked ? " (to \(ch.kind == .signal ? "Note to Self" : "Message yourself") — no notification)" : ""))
        return true
    }

    // MARK: Signal setup

    struct ConnectorReply {
        var ok: Bool
        var message: String?
        var captchaRequired = false
        var value: String?
        var data: Data?
    }

    private static func errorText(_ r: [String: Any]) -> String {
        if let res = r["result"] as? [String: Any], let e = res["error"] as? String { return e }
        if let s = r["result"] as? String, !s.isEmpty { return s }
        return "HTTP \(r["status"] ?? "?")"
    }

    /// Ask Signal to send a verification code to `number`, by SMS or voice
    /// call (Signal only calls after an SMS was tried for that number).
    func signalRegister(number: String, voice: Bool, captcha: String?) async -> ConnectorReply {
        guard let c = store.connector else { return .init(ok: false, message: "No connector") }
        var args = ["signal-register", number, voice ? "1" : "0"]
        if let captcha, !captcha.isEmpty { args.append(Self.b64(captcha)) }
        guard let r = try? await relay(c, args) else { return .init(ok: false, message: "The connector didn't answer") }
        let status = r["status"] as? Int ?? 0
        if (200..<300).contains(status) { return .init(ok: true) }
        let err = Self.errorText(r)
        return .init(ok: false, message: err, captchaRequired: err.lowercased().contains("captcha"))
    }

    /// The code the user received: on success the number is the Switchboard's.
    func signalVerify(number: String, code: String, userNumber: String) async -> ConnectorReply {
        guard var c = store.connector else { return .init(ok: false, message: "No connector") }
        guard let r = try? await relay(c, ["signal-verify", number, code]) else {
            return .init(ok: false, message: "The connector didn't answer")
        }
        let status = r["status"] as? Int ?? 0
        guard (200..<300).contains(status) else { return .init(ok: false, message: Self.errorText(r)) }
        c.signal = ConnectorChannel(kind: .signal, mode: .ownNumber, account: number,
                                    allowed: [userNumber], connected: true)
        store.upsert(c)
        try? await pushConnectorConfig(c)
        log(c.id, "Signal connected as its own number")
        return .init(ok: true)
    }

    /// A `sgnl://linkdevice?…` URI to show as a QR code; the link completes
    /// when the phone scans it (see `signalFinishLink`).
    func signalLinkURI() async -> ConnectorReply {
        guard let c = store.connector,
              let r = try? await relay(c, ["signal-link"], timeout: 90) else {
            return .init(ok: false, message: "The connector didn't answer")
        }
        if let res = r["result"] as? [String: Any], let uri = res["device_link_uri"] as? String {
            return .init(ok: true, value: uri)
        }
        return .init(ok: false, message: Self.errorText(r))
    }

    /// After the scan: the account signal-cli now holds is the user's own.
    func signalFinishLink() async -> ConnectorReply {
        guard var c = store.connector,
              let r = try? await relay(c, ["signal-accounts"]) else {
            return .init(ok: false, message: "The connector didn't answer")
        }
        guard let accounts = r["result"] as? [String], let account = accounts.last else {
            return .init(ok: false, message: nil)
        }
        c.signal = ConnectorChannel(kind: .signal, mode: .linked, account: account,
                                    allowed: [account], connected: true)
        store.upsert(c)
        try? await pushConnectorConfig(c)
        log(c.id, "Signal linked to \(account)")
        return .init(ok: true, value: account)
    }

    // MARK: Slack setup

    /// The app Bromure asks the user to create in their workspace: Socket
    /// Mode (no public URL — the connector dials out), direct messages only,
    /// the fewest scopes that work: read and answer DMs sent to the app.
    static let slackManifest: [String: Any] = [
        "_metadata": ["major_version": 1, "minor_version": 1],
        "display_information": [
            "name": "Bromure",
            "description": "Your Bromure Switchboard: ask what your coding sessions are up to.",
            "background_color": "#1f2330",
        ],
        "features": [
            "app_home": ["home_tab_enabled": false, "messages_tab_enabled": true,
                         "messages_tab_read_only_enabled": false],
            "bot_user": ["display_name": "Bromure", "always_online": true],
        ],
        "oauth_config": ["scopes": ["bot": ["chat:write", "im:history", "im:read", "im:write"]]],
        "settings": [
            "event_subscriptions": ["bot_events": ["message.im"]],
            "interactivity": ["is_enabled": false],
            "org_deploy_enabled": false,
            "socket_mode_enabled": true,
            "token_rotation_enabled": false,
        ],
    ]

    /// Slack's "create an app from this manifest" page, prefilled.
    static var slackCreateAppURL: URL? {
        guard let data = try? JSONSerialization.data(withJSONObject: slackManifest, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return nil }
        var c = URLComponents(string: "https://api.slack.com/apps")
        c?.queryItems = [URLQueryItem(name: "new_app", value: "1"), URLQueryItem(name: "manifest_json", value: json)]
        return c?.url
    }

    /// Hand the two tokens to the connector, which checks them with Slack
    /// and keeps them on its data disk. They travel as a file in a private
    /// folder (never a command line) and aren't kept on the Mac. On success
    /// the channel exists but answers nobody until pairing.
    func slackSetup(botToken: String, appToken: String) async -> ConnectorReply {
        guard var c = store.connector else { return .init(ok: false, message: "No connector") }
        let bot = botToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let app = appToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard bot.hasPrefix("xoxb-") else {
            return .init(ok: false, message: NSLocalizedString("The Bot User OAuth Token starts with xoxb-.", comment: "slack setup"))
        }
        guard app.hasPrefix("xapp-") else {
            return .init(ok: false, message: NSLocalizedString("The app-level token starts with xapp-.", comment: "slack setup"))
        }
        let dir = "/var/lib/bromure-msgbridge/incoming"
        let path = dir + "/slack-\(UUID().uuidString).json"
        guard let data = try? JSONSerialization.data(withJSONObject: ["botToken": bot, "appToken": app]),
              (try? await exec(c.node.id, "mkdir -p \(dir) && chmod 700 \(dir) && echo ok", timeout: 15))?
                .contains("ok") == true,
              (try? await app_writeFile(c.node.id, path: path, data: data)) == true,
              let r = try? await relay(c, ["slack-setup", path], timeout: 60)
        else {
            _ = try? await exec(c.node.id, "rm -f \(Self.shellQuote(path))", timeout: 15)
            return .init(ok: false, message: "The connector didn't answer")
        }
        guard r["ok"] as? Bool == true else {
            return .init(ok: false, message: r["error"] as? String ?? "Slack refused the tokens")
        }
        let team = r["team"] as? String
        c.slack = ConnectorChannel(kind: .slack, mode: .ownNumber, account: r["botUserID"] as? String,
                                   allowed: [], connected: false,
                                   workspace: team, workspaceID: r["teamID"] as? String)
        store.upsert(c)
        log(c.id, "Slack app set up in \(team ?? "a workspace") — waiting for pairing")
        return .init(ok: true, value: team)
    }

    /// A fresh one-time pairing code (six digits, good for 10 minutes): the
    /// first person to send it to the app in a direct message becomes the
    /// only Slack account Bromure answers.
    func slackStartPairing() -> String {
        let code = String(format: "%06d", Int.random(in: 0...999_999))
        slackPairing = (code, Date().addingTimeInterval(600))
        slackPairingMisses = 0
        slackPairingAborted = false
        if let c = store.connector { log(c.id, "Slack pairing started") }
        return code
    }

    private func app_writeFile(_ nodeID: UUID, path: String, data: Data) async throws -> Bool {
        for op in GuestDrop.writeOps(guestPath: path, data: data) {
            _ = try await app.guestFileOp(profileID: nodeID, op: op, timeout: 30)
        }
        return true
    }

    // MARK: WhatsApp setup

    /// The QR code (PNG) to scan in WhatsApp › Linked devices.
    func whatsappQR() async -> ConnectorReply {
        guard let c = store.connector,
              let r = try? await relay(c, ["wa-login-qr"]) else {
            return .init(ok: false, message: "The connector didn't answer")
        }
        if let b64 = r["png"] as? String, let png = Data(base64Encoded: b64), !png.isEmpty {
            return .init(ok: true, data: png)
        }
        return .init(ok: false, message: Self.errorText(r))
    }

    /// An 8-character code to type in WhatsApp › Linked devices › Link with
    /// phone number instead — for when scanning isn't practical.
    func whatsappPairingCode(phone: String) async -> ConnectorReply {
        guard let c = store.connector,
              let r = try? await relay(c, ["wa-pair", Self.digits(phone)]) else {
            return .init(ok: false, message: "The connector didn't answer")
        }
        if let res = r["result"] as? [String: Any], let results = res["results"] as? [String: Any],
           let code = results["pair_code"] as? String {
            return .init(ok: true, value: code)
        }
        return .init(ok: false, message: Self.errorText(r))
    }

    /// Once WhatsApp reports the device logged in, record the channel.
    /// `mode`/`userPhone` are what the user picked in the sheet.
    func whatsappFinishLink(mode: ConnectorChannel.Mode, userPhone: String?) async -> ConnectorReply {
        guard var c = store.connector,
              let r = try? await relay(c, ["wa-status"]) else {
            return .init(ok: false, message: "The connector didn't answer")
        }
        guard (r["result"] as? [String: Any])?["is_logged_in"] as? Bool == true else {
            return .init(ok: false, message: nil)
        }
        // The account's JID: the status says it once logged in; else
        // wherever the device list puts it.
        let blob = (try? JSONSerialization.data(withJSONObject: r["devices"] ?? [:])).map { String(decoding: $0, as: UTF8.self) } ?? ""
        let statusJID = ((r["result"] as? [String: Any])?["jid"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let jid = statusJID ?? blob.range(of: #"[0-9]+(:[0-9]+)?@s\.whatsapp\.net"#, options: .regularExpression)
            .map { String(blob[$0]) }
        let account = jid.map { Self.digits($0) + "@s.whatsapp.net" }
        let allowed: [String] = mode == .linked
            ? [account].compactMap { $0 }
            : [userPhone].compactMap { $0.map { Self.digits($0) + "@s.whatsapp.net" } }
        c.whatsapp = ConnectorChannel(kind: .whatsapp, mode: mode, account: account,
                                      allowed: allowed, connected: true)
        store.upsert(c)
        log(c.id, "WhatsApp connected\(account.map { " as \($0)" } ?? "")")
        return .init(ok: true, value: account)
    }

    func disconnect(_ kind: ConnectorChannel.Kind) async {
        guard var c = store.connector else { return }
        switch kind {
        case .signal:
            // Only the Switchboard's OWN number is unregistered. A linked
            // device is the user's account: unregistering from here could
            // touch their phone's registration — the link is just forgotten,
            // and they remove the device in Signal › Linked devices.
            if c.signal?.mode == .ownNumber, let n = c.signal?.account {
                _ = try? await relay(c, ["signal-unregister", n])
            }
            c.signal = nil
        case .whatsapp:
            _ = try? await relay(c, ["wa-logout"])
            c.whatsapp = nil
        case .slack:
            // The tokens go from the connector; the app itself stays in the
            // user's Slack workspace until they remove it there.
            _ = try? await relay(c, ["slack-logout"])
            c.slack = nil
            slackPairing = nil
        }
        store.upsert(c)
        try? await pushConnectorConfig(c)
        log(c.id, "\(kind.displayName) disconnected")
    }
}
#endif
