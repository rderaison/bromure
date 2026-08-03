import Foundation
import Security

// MARK: - Host credential discovery
//
// Walks the well-known config files a developer already has on their Mac and
// reports what each one holds, so the onboarding wizard can offer to bring them
// in. Nothing is read until the user opts in, and nothing is imported until
// they tick it.
//
// Why importing is SAFER than the files it reads from: every secret lifted here
// is stored host-side and the VM receives only a fake, which the proxy swaps
// back on outbound requests to that host. The files themselves hold the secrets
// in cleartext, so an imported credential is strictly better protected than the
// original — and the guest never needs the user's real dotfiles mounted.
//
// Adding a source: write a `detect…()` that returns a `Finding` with a payload,
// list it in `scan()`, and handle its payload in `apply(_:to:)`.
enum ConfigScan {

    // MARK: Findings

    enum Kind: String {
        case gitconfig, gitCredentials, docker, awsStatic, awsSSO, kube
        case npm, ghCLI, glabCLI, netrc, doctl, pypi, cargo
        case claudeSubscription, codexSubscription, grokSubscription, kimiSubscription
        case agentAPIKey, sshKey, envFile
    }

    /// What `apply` needs, captured at scan time so nothing is re-read (and no
    /// secret is held longer than the wizard's lifetime).
    enum Payload {
        case git(identity: (name: String, email: String), creds: [GitCred])
        case docker([DockerConfigImport.Entry])
        case awsStatic(accessKeyID: String, secret: String, session: String)
        case awsSSO([DiscoveredSSOProfile])
        case kube([KubeconfigEntry])
        /// A token that has no typed home on Profile — lands as a ManualToken
        /// exported under `envVar` and scoped to `hosts`.
        case manual(name: String, value: String, envVar: String, hosts: [String])
        case digitalOcean(String)
        case gitTokens([GitCred])
        case subscription(provider: String, access: String, refresh: String)
        /// A subscription whose tokens live in the login keychain. The secret
        /// is read at IMPORT time, not scan time — reading another app's item
        /// raises a macOS access prompt, which must not fire from a scan the
        /// user hasn't agreed to act on yet.
        case keychainSubscription(provider: String, service: String)
        case sshKey(label: String)
        case env([EnvFileImport.ParsedVar])
        case agentKeys([(tool: Profile.Tool, value: String)])
    }

    struct GitCred: Equatable {
        let host: String
        let username: String
        let token: String
    }

    struct Finding: Identifiable {
        let id: String
        let kind: Kind
        let path: URL
        let title: String
        let detail: String
        /// How many individual secrets this row would bring in (drives the
        /// "Import N credentials" button).
        let credentialCount: Int
        let symbol: String
        var include: Bool = true
        let payload: Payload

        var displayPath: String {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            return path.path.hasPrefix(home)
                ? "~" + path.path.dropFirst(home.count)
                : path.path
        }
    }

    struct SubscriptionImport {
        let provider: String
        let access: String
        let refresh: String
    }

    struct Summary {
        var total = 0
        /// SSH keys can only be copied once the profile exists on disk, so the
        /// caller finishes these after saving.
        var deferredSSHKeys: [(url: URL, label: String)] = []
        /// Subscription tokens go to the MITM stores, not the profile.
        var subscriptions: [SubscriptionImport] = []
        var headline = ""
        var detail = ""
    }

    // MARK: Scan

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    static func scan() -> [Finding] {
        var out: [Finding] = []
        for probe in [detectGitConfig, detectGitCredentials, detectDocker,
                      detectAWSStatic, detectAWSSSO, detectKube, detectNPM,
                      detectGHCLI, detectGlabCLI, detectNetrc, detectDoctl,
                      detectPyPI, detectCargo, detectClaudeSubscription,
                      detectCodexSubscription, detectGrokSubscription,
                      detectKimiSubscription, detectClaudeSettingsKeys] {
            if let f = probe() { out.append(f) }
        }
        out.append(contentsOf: detectSSHKeys())
        return out
    }

    private static func text(_ url: URL) -> String? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return String(data: d, encoding: .utf8) ?? String(data: d, encoding: .isoLatin1)
    }

    // MARK: git

    private static func detectGitConfig() -> Finding? {
        let url = home.appendingPathComponent(".gitconfig")
        guard let body = text(url), let r = try? GitConfigParse.parse(body) else { return nil }
        guard !r.identity.name.isEmpty || !r.identity.email.isEmpty || !r.creds.isEmpty else { return nil }
        var bits: [String] = []
        if !r.identity.name.isEmpty || !r.identity.email.isEmpty {
            bits.append("identity \(r.identity.email.isEmpty ? r.identity.name : r.identity.email)")
        }
        if !r.creds.isEmpty { bits.append("\(r.creds.count) embedded token(s)") }
        return Finding(id: Kind.gitconfig.rawValue, kind: .gitconfig, path: url,
                       title: "Git config", detail: bits.joined(separator: ", "),
                       credentialCount: r.creds.count,
                       symbol: "arrow.triangle.branch",
                       payload: .git(identity: r.identity, creds: r.creds))
    }

    private static func detectGitCredentials() -> Finding? {
        let url = home.appendingPathComponent(".git-credentials")
        guard let body = text(url) else { return nil }
        // git's `store` helper: one URL per line, credentials in the userinfo.
        let creds = body.split(whereSeparator: \.isNewline)
            .compactMap { GitConfigParse.credential(fromURL: String($0)) }
        guard !creds.isEmpty else { return nil }
        let hosts = Set(creds.map(\.host)).sorted().joined(separator: ", ")
        return Finding(id: Kind.gitCredentials.rawValue, kind: .gitCredentials, path: url,
                       title: "Git saved passwords", detail: "\(creds.count) token(s): \(hosts)",
                       credentialCount: creds.count, symbol: "key.fill",
                       payload: .gitTokens(creds))
    }

    // MARK: docker

    private static func detectDocker() -> Finding? {
        let url = home.appendingPathComponent(".docker/config.json")
        guard let d = try? Data(contentsOf: url),
              let r = try? DockerConfigImport.parse(d), !r.entries.isEmpty else { return nil }
        var detail = "\(r.entries.count) registry login(s): "
            + r.entries.map(\.host).joined(separator: ", ")
        if r.skippedHelper > 0 { detail += " (\(r.skippedHelper) in a credential helper, skipped)" }
        return Finding(id: Kind.docker.rawValue, kind: .docker, path: url,
                       title: "Docker registries", detail: detail,
                       credentialCount: r.entries.count, symbol: "shippingbox.fill",
                       payload: .docker(r.entries))
    }

    // MARK: aws

    private static func detectAWSStatic() -> Finding? {
        let url = home.appendingPathComponent(".aws/credentials")
        guard let body = text(url) else { return nil }
        let ini = INI.parse(body)
        // Prefer [default]; else the first profile that has a key pair.
        let section = ini.first(where: { $0.name == "default" && $0.values["aws_access_key_id"] != nil })
            ?? ini.first(where: { $0.values["aws_access_key_id"] != nil })
        guard let s = section,
              let key = s.values["aws_access_key_id"], !key.isEmpty,
              let secret = s.values["aws_secret_access_key"], !secret.isEmpty else { return nil }
        return Finding(id: Kind.awsStatic.rawValue, kind: .awsStatic, path: url,
                       title: "AWS access keys",
                       detail: "profile \"\(s.name)\", key \(redactTail(key))",
                       credentialCount: 1, symbol: "cloud.fill",
                       payload: .awsStatic(accessKeyID: key, secret: secret,
                                           session: s.values["aws_session_token"] ?? ""))
    }

    private static func detectAWSSSO() -> Finding? {
        let url = home.appendingPathComponent(".aws/config")
        let profiles = AWSConfigParser.discover(configPath: url.path)
        guard !profiles.isEmpty else { return nil }
        return Finding(id: Kind.awsSSO.rawValue, kind: .awsSSO, path: url,
                       title: "AWS SSO profiles",
                       detail: profiles.prefix(3).map(\.name).joined(separator: ", ")
                            + (profiles.count > 3 ? " +\(profiles.count - 3) more" : ""),
                       credentialCount: profiles.count, symbol: "person.badge.key.fill",
                       payload: .awsSSO(profiles))
    }

    // MARK: kubernetes

    private static func detectKube() -> Finding? {
        let url = home.appendingPathComponent(".kube/config")
        guard let body = text(url),
              let ctxs = try? KubeconfigImport.parse(body), !ctxs.isEmpty else { return nil }
        return Finding(id: Kind.kube.rawValue, kind: .kube, path: url,
                       title: "Kubernetes contexts",
                       detail: ctxs.prefix(3).map(\.name).joined(separator: ", ")
                            + (ctxs.count > 3 ? " +\(ctxs.count - 3) more" : ""),
                       credentialCount: ctxs.count, symbol: "helm",
                       payload: .kube(ctxs))
    }

    // MARK: language / package registries

    private static func detectNPM() -> Finding? {
        let url = home.appendingPathComponent(".npmrc")
        guard let body = text(url) else { return nil }
        // `//registry.npmjs.org/:_authToken=xxx`
        for line in body.split(whereSeparator: \.isNewline) {
            let l = line.trimmingCharacters(in: .whitespaces)
            guard l.contains(":_authToken="), let eq = l.firstIndex(of: "=") else { continue }
            let token = unquote(String(l[l.index(after: eq)...]).trimmingCharacters(in: .whitespaces))
            guard !token.isEmpty, !token.hasPrefix("${") else { continue }
            let registry = String(l[..<l.range(of: ":_authToken=")!.lowerBound])
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let hostOnly = registry.split(separator: "/").first.map(String.init) ?? "registry.npmjs.org"
            return Finding(id: Kind.npm.rawValue, kind: .npm, path: url,
                           title: "npm token", detail: "registry \(hostOnly)",
                           credentialCount: 1, symbol: "cube.box.fill",
                           payload: .manual(name: "npm (\(hostOnly))", value: token,
                                            envVar: "NPM_TOKEN", hosts: [hostOnly]))
        }
        return nil
    }

    private static func detectPyPI() -> Finding? {
        let url = home.appendingPathComponent(".pypirc")
        guard let body = text(url) else { return nil }
        for s in INI.parse(body) {
            guard let pw = s.values["password"], !pw.isEmpty else { continue }
            return Finding(id: Kind.pypi.rawValue, kind: .pypi, path: url,
                           title: "PyPI token", detail: "index \"\(s.name)\"",
                           credentialCount: 1, symbol: "shippingbox",
                           payload: .manual(name: "PyPI (\(s.name))", value: pw,
                                            envVar: "TWINE_PASSWORD", hosts: ["pypi.org"]))
        }
        return nil
    }

    private static func detectCargo() -> Finding? {
        for name in [".cargo/credentials.toml", ".cargo/credentials"] {
            let url = home.appendingPathComponent(name)
            guard let body = text(url) else { continue }
            // [registry]\n token = "…"
            for line in body.split(whereSeparator: \.isNewline) {
                let l = line.trimmingCharacters(in: .whitespaces)
                guard l.hasPrefix("token"), let eq = l.firstIndex(of: "=") else { continue }
                let token = unquote(String(l[l.index(after: eq)...]).trimmingCharacters(in: .whitespaces))
                guard !token.isEmpty else { continue }
                return Finding(id: Kind.cargo.rawValue, kind: .cargo, path: url,
                               title: "crates.io token", detail: "cargo registry",
                               credentialCount: 1, symbol: "shippingbox",
                               payload: .manual(name: "crates.io", value: token,
                                                envVar: "CARGO_REGISTRY_TOKEN",
                                                hosts: ["crates.io"]))
            }
        }
        return nil
    }

    // MARK: forge CLIs

    private static func detectGHCLI() -> Finding? {
        let url = home.appendingPathComponent(".config/gh/hosts.yml")
        guard let body = text(url) else { return nil }
        let creds = YAMLLite.hostTokens(body, tokenKeys: ["oauth_token"], userKeys: ["user"])
        guard !creds.isEmpty else { return nil }
        return Finding(id: Kind.ghCLI.rawValue, kind: .ghCLI, path: url,
                       title: "GitHub CLI login",
                       detail: creds.map { "\($0.host)\($0.username.isEmpty ? "" : " (\($0.username))")" }
                            .joined(separator: ", "),
                       credentialCount: creds.count, symbol: "terminal.fill",
                       payload: .gitTokens(creds))
    }

    private static func detectGlabCLI() -> Finding? {
        for rel in [".config/glab-cli/config.yml", ".config/glab-cli/aliases.yml"] {
            let url = home.appendingPathComponent(rel)
            guard let body = text(url) else { continue }
            let creds = YAMLLite.hostTokens(body, tokenKeys: ["token"], userKeys: ["username", "user"])
            guard !creds.isEmpty else { continue }
            return Finding(id: Kind.glabCLI.rawValue, kind: .glabCLI, path: url,
                           title: "GitLab CLI login",
                           detail: creds.map(\.host).joined(separator: ", "),
                           credentialCount: creds.count, symbol: "terminal.fill",
                           payload: .gitTokens(creds))
        }
        return nil
    }

    private static func detectNetrc() -> Finding? {
        for name in [".netrc", "_netrc"] {
            let url = home.appendingPathComponent(name)
            guard let body = text(url) else { continue }
            let creds = parseNetrc(body)
            guard !creds.isEmpty else { continue }
            return Finding(id: Kind.netrc.rawValue, kind: .netrc, path: url,
                           title: "netrc logins",
                           detail: creds.map(\.host).joined(separator: ", "),
                           credentialCount: creds.count, symbol: "doc.text.fill",
                           payload: .gitTokens(creds))
        }
        return nil
    }

    /// `machine host login user password secret`, in any order, possibly across
    /// lines. `default` acts as a catch-all machine and is skipped (it has no
    /// host to scope a swap to).
    static func parseNetrc(_ body: String) -> [GitCred] {
        var out: [GitCred] = []
        var host = "", login = "", password = ""
        func flush() {
            if !host.isEmpty, !password.isEmpty {
                out.append(GitCred(host: host.lowercased(),
                                   username: login.isEmpty ? "x-access-token" : login,
                                   token: password))
            }
            host = ""; login = ""; password = ""
        }
        var tokens = body.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            .map(String.init).makeIterator()
        while let t = tokens.next() {
            switch t {
            case "machine": flush(); host = tokens.next() ?? ""
            case "default": flush()
            case "login":   login = tokens.next() ?? ""
            case "password": password = tokens.next() ?? ""
            case "account": _ = tokens.next()
            default: break
            }
        }
        flush()
        return out
    }

    // MARK: cloud CLIs

    private static func detectDoctl() -> Finding? {
        let url = home.appendingPathComponent("Library/Application Support/doctl/config.yaml")
        let alt = home.appendingPathComponent(".config/doctl/config.yaml")
        for u in [url, alt] {
            guard let body = text(u) else { continue }
            for line in body.split(whereSeparator: \.isNewline) {
                let l = line.trimmingCharacters(in: .whitespaces)
                guard l.hasPrefix("access-token:") else { continue }
                let token = unquote(String(l.dropFirst("access-token:".count))
                    .trimmingCharacters(in: .whitespaces))
                guard !token.isEmpty else { continue }
                return Finding(id: Kind.doctl.rawValue, kind: .doctl, path: u,
                               title: "DigitalOcean token", detail: "doctl CLI",
                               credentialCount: 1, symbol: "cloud",
                               payload: .digitalOcean(token))
            }
        }
        return nil
    }

    // MARK: agent subscriptions (the user's own CLI logins)

    /// Claude Code on macOS keeps its OAuth tokens in the LOGIN KEYCHAIN
    /// ("Claude Code-credentials"), not in `~/.claude/.credentials.json` —
    /// that path is where the *Linux* build (and our guest) stores them. Check
    /// the keychain first, then fall back to the file.
    private static let claudeKeychainService = "Claude Code-credentials"

    private static func detectClaudeSubscription() -> Finding? {
        if keychainItemExists(service: claudeKeychainService) {
            return Finding(id: Kind.claudeSubscription.rawValue, kind: .claudeSubscription,
                           path: URL(fileURLWithPath: "/Keychain/\(claudeKeychainService)"),
                           title: "Claude subscription",
                           detail: "your Claude Code login, from the login keychain",
                           credentialCount: 1, symbol: "sparkles",
                           payload: .keychainSubscription(provider: "claude",
                                                          service: claudeKeychainService))
        }
        let url = home.appendingPathComponent(".claude/.credentials.json")
        guard let d = try? Data(contentsOf: url),
              let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let access = oauth["accessToken"] as? String,
              let refresh = oauth["refreshToken"] as? String,
              !access.isEmpty, !refresh.isEmpty else { return nil }
        return Finding(id: Kind.claudeSubscription.rawValue, kind: .claudeSubscription, path: url,
                       title: "Claude subscription",
                       detail: "your Claude Code login — skips the register-with-Claude step",
                       credentialCount: 1, symbol: "sparkles",
                       payload: .subscription(provider: "claude", access: access, refresh: refresh))
    }

    private static func detectCodexSubscription() -> Finding? {
        let url = home.appendingPathComponent(".codex/auth.json")
        guard let d = try? Data(contentsOf: url),
              let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let tokens = obj["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String,
              let refresh = tokens["refresh_token"] as? String,
              !access.isEmpty, !refresh.isEmpty else { return nil }
        return Finding(id: Kind.codexSubscription.rawValue, kind: .codexSubscription, path: url,
                       title: "ChatGPT subscription",
                       detail: "your Codex CLI login — skips the register-with-ChatGPT step",
                       credentialCount: 1, symbol: "sparkles",
                       payload: .subscription(provider: "codex", access: access, refresh: refresh))
    }

    /// Grok CLI: `~/.grok/auth.json` — `{ "<scope>": { key, refresh_token, … } }`.
    /// The scope key is account-specific, so take the first entry that carries
    /// a token pair rather than guessing its name.
    private static func detectGrokSubscription() -> Finding? {
        let url = home.appendingPathComponent(".grok/auth.json")
        guard let d = try? Data(contentsOf: url),
              let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
        for (_, raw) in obj {
            guard let e = raw as? [String: Any],
                  let access = e["key"] as? String,
                  let refresh = e["refresh_token"] as? String,
                  !access.isEmpty, !refresh.isEmpty else { continue }
            return Finding(id: Kind.grokSubscription.rawValue, kind: .grokSubscription, path: url,
                           title: "Grok subscription",
                           detail: "your Grok CLI login — skips the register-with-Grok step",
                           credentialCount: 1, symbol: "sparkles",
                           payload: .subscription(provider: "grok", access: access, refresh: refresh))
        }
        return nil
    }

    /// Kimi CLI: `~/.kimi-code/credentials/<name>.json` — one file per
    /// credential, `{ access_token, refresh_token, … }`.
    private static func detectKimiSubscription() -> Finding? {
        let dir = home.appendingPathComponent(".kimi-code/credentials", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
        for name in names.sorted() where name.hasSuffix(".json") {
            let url = dir.appendingPathComponent(name)
            guard let d = try? Data(contentsOf: url),
                  let e = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                  let access = e["access_token"] as? String,
                  let refresh = e["refresh_token"] as? String,
                  !access.isEmpty, !refresh.isEmpty else { continue }
            return Finding(id: Kind.kimiSubscription.rawValue, kind: .kimiSubscription, path: url,
                           title: "Kimi subscription",
                           detail: "your Kimi CLI login — skips the register-with-Kimi step",
                           credentialCount: 1, symbol: "sparkles",
                           payload: .subscription(provider: "kimi", access: access, refresh: refresh))
        }
        return nil
    }

    /// Agent API keys that live in a CLI's own settings rather than the shell:
    /// Claude Code keeps an `env` block in `~/.claude/settings.json`, and Codex
    /// an `[env]`-ish table in `~/.codex/config.toml`. Both are common for
    /// people who never exported the key from a dotfile.
    private static func detectClaudeSettingsKeys() -> Finding? {
        var found: [(tool: Profile.Tool, value: String)] = []
        var sources: [String] = []

        let settings = home.appendingPathComponent(".claude/settings.json")
        if let d = try? Data(contentsOf: settings),
           let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
           let env = obj["env"] as? [String: Any] {
            for (k, v) in env {
                guard let s = v as? String, !s.isEmpty,
                      case let .toolKey(tool)? = EnvFileImport.slot(forName: k) else { continue }
                found.append((tool, s))
            }
            if !found.isEmpty { sources.append("settings.json") }
        }

        let codex = home.appendingPathComponent(".codex/config.toml")
        if let body = text(codex) {
            for line in body.split(whereSeparator: \.isNewline) {
                let l = line.trimmingCharacters(in: .whitespaces)
                guard let eq = l.firstIndex(of: "="), !l.hasPrefix("#") else { continue }
                let key = String(l[..<eq]).trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                guard case let .toolKey(tool)? = EnvFileImport.slot(forName: key) else { continue }
                let v = unquote(String(l[l.index(after: eq)...]).trimmingCharacters(in: .whitespaces))
                guard !v.isEmpty, !v.hasPrefix("${") else { continue }
                if !found.contains(where: { $0.tool == tool }) { found.append((tool, v)) }
                if !sources.contains("config.toml") { sources.append("config.toml") }
            }
        }

        guard !found.isEmpty else { return nil }
        let names = found.map { $0.tool.rawValue }.joined(separator: ", ")
        return Finding(id: Kind.agentAPIKey.rawValue, kind: .agentAPIKey,
                       path: sources.first == "config.toml" ? codex : settings,
                       title: "Agent API keys", detail: "\(names) (from \(sources.joined(separator: " + ")))",
                       credentialCount: found.count, symbol: "key.horizontal.fill",
                       payload: .agentKeys(found))
    }

    // MARK: ssh

    private static func detectSSHKeys() -> [Finding] {
        let dir = home.appendingPathComponent(".ssh", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        var out: [Finding] = []
        for name in names.sorted() where name.hasPrefix("id_") && !name.hasSuffix(".pub") {
            let url = dir.appendingPathComponent(name)
            guard let head = text(url)?.prefix(120), head.contains("PRIVATE KEY") else { continue }
            // An encrypted key needs a passphrase we can't prompt for mid-scan.
            let encrypted = head.contains("ENCRYPTED") || head.contains("Proc-Type: 4,ENCRYPTED")
            out.append(Finding(
                id: "\(Kind.sshKey.rawValue):\(name)", kind: .sshKey, path: url,
                title: "SSH key \(name)",
                detail: encrypted
                    ? "passphrase-protected — you'll be asked for it after setup"
                    : "used for git over SSH inside the VM",
                credentialCount: 1, symbol: "key.horizontal",
                include: !encrypted,          // don't silently commit to a prompt
                payload: .sshKey(label: name)))
        }
        return out
    }

    // MARK: env files (hand-picked)

    static func envFinding(at url: URL) -> Finding? {
        guard let body = text(url) else { return nil }
        let vars = EnvFileImport.parse(body)
        let known = vars.filter { EnvFileImport.slot(forName: $0.name) != nil }
        guard !known.isEmpty else { return nil }
        return Finding(id: "env:\(url.path)", kind: .envFile, path: url,
                       title: "Env file", detail: "\(known.count) recognized variable(s)",
                       credentialCount: known.count, symbol: "doc.plaintext.fill",
                       payload: .env(vars))
    }

    // MARK: - Keychain

    /// Does a generic-password item exist for `service`? Attributes only — no
    /// `kSecReturnData`, so macOS does NOT prompt for access. Presence is all a
    /// scan needs; the secret is fetched later, once the user ticks the row.
    static func keychainItemExists(service: String) -> Bool {
        let q: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecReturnAttributes: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess
    }

    /// Read a generic password. This is what raises the access prompt, so call
    /// it only from `apply` — after the user has chosen to import.
    static func keychainSecret(service: String) -> String? {
        let q: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Pull an OAuth pair out of a provider's stored JSON. Claude Code uses the
    /// same `claudeAiOauth` shape in the keychain as it does in its file.
    static func oauthPair(fromJSON json: String, provider: String) -> (String, String)? {
        guard let d = json.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
        else { return nil }
        switch provider {
        case "claude":
            guard let o = obj["claudeAiOauth"] as? [String: Any],
                  let a = o["accessToken"] as? String,
                  let r = o["refreshToken"] as? String, !a.isEmpty, !r.isEmpty else { return nil }
            return (a, r)
        case "codex":
            guard let tk = obj["tokens"] as? [String: Any],
                  let a = tk["access_token"] as? String,
                  let r = tk["refresh_token"] as? String, !a.isEmpty, !r.isEmpty else { return nil }
            return (a, r)
        default:
            return nil
        }
    }

    // MARK: - Apply

    /// Fold the chosen findings into a workspace draft. Secrets that have no
    /// typed home become `ManualToken`s (exported under an env var, swapped on
    /// their host). SSH keys and subscription logins can't be written to a
    /// draft, so they come back in the summary for the caller to finish.
    static func apply(_ findings: [Finding], to profile: inout Profile) -> Summary {
        var s = Summary()

        func addGit(_ creds: [GitCred]) {
            for c in creds {
                guard !c.token.isEmpty, !c.host.isEmpty else { continue }
                if let i = profile.gitHTTPSCredentials.firstIndex(where: {
                    $0.host.lowercased() == c.host.lowercased() && $0.username == c.username
                }) {
                    if profile.gitHTTPSCredentials[i].token.isEmpty {
                        profile.gitHTTPSCredentials[i].token = c.token
                        s.total += 1
                    }
                } else {
                    profile.gitHTTPSCredentials.append(
                        GitHTTPSCredential(host: c.host, username: c.username, token: c.token))
                    s.total += 1
                }
            }
        }

        for f in findings where f.include {
            switch f.payload {
            case .git(let identity, let creds):
                if profile.gitUserName.isEmpty { profile.gitUserName = identity.name }
                if profile.gitUserEmail.isEmpty { profile.gitUserEmail = identity.email }
                addGit(creds)

            case .gitTokens(let creds):
                addGit(creds)

            case .docker(let entries):
                for e in entries {
                    let dup = profile.dockerRegistries.contains {
                        $0.host.lowercased() == e.host.lowercased() && $0.username == e.username
                    }
                    if dup { continue }
                    profile.dockerRegistries.append(DockerRegistryCredential(
                        host: e.host, username: e.username, password: e.password))
                    s.total += 1
                }

            case .awsStatic(let key, let secret, let session):
                profile.awsCredentials.authMode = .staticKeys
                profile.awsCredentials.accessKeyID = key
                profile.awsCredentials.secretAccessKey = secret
                if !session.isEmpty { profile.awsCredentials.sessionToken = session }
                s.total += 1

            case .awsSSO(let profiles):
                // Static keys win if both were ticked — they need no browser.
                if profile.awsCredentials.authMode != .staticKeys, let first = profiles.first {
                    profile.awsCredentials.authMode = .ssoProfile
                    profile.awsCredentials.ssoProfileName = first.name
                    profile.awsCredentials.ssoAccountId = first.ssoAccountID
                    profile.awsCredentials.ssoRoleName = first.ssoRoleName
                    if profile.awsCredentials.region.isEmpty {
                        profile.awsCredentials.region = first.region.isEmpty ? first.ssoRegion : first.region
                    }
                    s.total += 1
                }

            case .kube(let ctxs):
                // KubeconfigImport already produced fully-formed entries
                // (auth kind, CA, namespace), so this is a straight merge.
                for e in ctxs where !profile.kubeconfigs.contains(where: { $0.name == e.name }) {
                    profile.kubeconfigs.append(e)
                    s.total += 1
                }

            case .digitalOcean(let token):
                if profile.digitalOceanToken.isEmpty {
                    profile.digitalOceanToken = token
                    s.total += 1
                }

            case .manual(let name, let value, let envVar, let hosts):
                guard !profile.manualTokens.contains(where: { $0.name == name }) else { continue }
                profile.manualTokens.append(ManualToken(
                    name: name, realValue: value, envVarName: envVar, hostFilters: hosts))
                s.total += 1

            case .agentKeys(let keys):
                for (tool, value) in keys {
                    if profile.tool == tool {
                        profile.apiKey = value; profile.authMode = .token
                    } else if let i = profile.additionalTools.firstIndex(where: { $0.tool == tool }) {
                        profile.additionalTools[i].apiKey = value
                        profile.additionalTools[i].authMode = .token
                    } else {
                        profile.additionalTools.append(.init(tool: tool, authMode: .token, apiKey: value))
                    }
                    s.total += 1
                }

            case .keychainSubscription(let provider, let service):
                // Reads the item — macOS may ask the user to allow access.
                // That prompt belongs here, at explicit import, not in a scan.
                guard let json = keychainSecret(service: service),
                      let (access, refresh) = oauthPair(fromJSON: json, provider: provider) else {
                    continue
                }
                s.subscriptions.append(SubscriptionImport(
                    provider: provider, access: access, refresh: refresh))
                s.total += 1

            case .subscription(let provider, let access, let refresh):
                s.subscriptions.append(SubscriptionImport(
                    provider: provider, access: access, refresh: refresh))
                s.total += 1

            case .sshKey(let label):
                s.deferredSSHKeys.append((url: f.path, label: label))
                s.total += 1

            case .env(let vars):
                for v in vars {
                    guard let slot = EnvFileImport.slot(forName: v.name) else { continue }
                    switch slot {
                    case .toolKey(let t):
                        if profile.tool == t {
                            profile.apiKey = v.value; profile.authMode = .token
                        } else if let i = profile.additionalTools.firstIndex(where: { $0.tool == t }) {
                            profile.additionalTools[i].apiKey = v.value
                            profile.additionalTools[i].authMode = .token
                        } else {
                            profile.additionalTools.append(
                                .init(tool: t, authMode: .token, apiKey: v.value))
                        }
                    case .gitToken(let host):
                        addGit([GitCred(host: host, username: "x-access-token", token: v.value)])
                        continue                       // addGit counted it
                    case .digitalOcean: profile.digitalOceanToken = v.value
                    case .linear:       profile.linearToken = v.value
                    case .awsAccessKeyID:
                        profile.awsCredentials.authMode = .staticKeys
                        profile.awsCredentials.accessKeyID = v.value
                    case .awsSecretAccessKey:
                        profile.awsCredentials.authMode = .staticKeys
                        profile.awsCredentials.secretAccessKey = v.value
                    case .awsSessionToken:
                        profile.awsCredentials.sessionToken = v.value
                    }
                    s.total += 1
                }
            }
        }

        s.headline = s.total == 1
            ? NSLocalizedString("Imported 1 credential.", comment: "")
            : String(format: NSLocalizedString("Imported %d credentials.", comment: ""), s.total)
        var bits: [String] = []
        if s.total > 0 {
            bits.append(NSLocalizedString(
                "Each one stays on this Mac — the VM only ever receives a fake, swapped back by the proxy.",
                comment: ""))
        }
        if !s.deferredSSHKeys.isEmpty {
            bits.append(String(format: NSLocalizedString(
                "%d SSH key(s) will be copied into the workspace.", comment: ""),
                s.deferredSSHKeys.count))
        }
        s.detail = bits.joined(separator: " ")
        return s
    }

    // MARK: - Small helpers

    private static func unquote(_ v: String) -> String {
        var s = v
        if s.count >= 2, (s.hasPrefix("\"") && s.hasSuffix("\"")) || (s.hasPrefix("'") && s.hasSuffix("'")) {
            s = String(s.dropFirst().dropLast())
        }
        return s
    }

    private static func redactTail(_ s: String) -> String {
        s.count <= 4 ? "…" : "…" + s.suffix(4)
    }
}

// MARK: - Minimal INI (aws credentials, pypirc)

enum INI {
    struct Section { let name: String; var values: [String: String] }

    static func parse(_ text: String) -> [Section] {
        var out: [Section] = []
        var current: Section?
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = String(raw)
            if let hash = line.firstIndex(where: { $0 == "#" || $0 == ";" }) {
                line = String(line[..<hash])
            }
            line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("[") {
                if let c = current { out.append(c) }
                var name = line.dropFirst()
                if let close = name.lastIndex(of: "]") { name = name[..<close] }
                // `[profile foo]` in ~/.aws/config → "foo".
                var n = name.trimmingCharacters(in: .whitespaces)
                if n.hasPrefix("profile ") { n = String(n.dropFirst("profile ".count)) }
                current = Section(name: n, values: [:])
                continue
            }
            guard let eq = line.firstIndex(of: "="), current != nil else { continue }
            let k = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let v = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            current?.values[k] = v
        }
        if let c = current { out.append(c) }
        return out
    }
}

// MARK: - Enough YAML for the forge CLIs' host maps
//
// gh/glab configs are a flat two-level map: a host key, then indented
// `key: value` pairs. A real YAML parser would be overkill (and a dependency),
// so this reads exactly that shape and ignores anything else.
enum YAMLLite {
    static func hostTokens(_ text: String,
                           tokenKeys: [String],
                           userKeys: [String]) -> [ConfigScan.GitCred] {
        var out: [ConfigScan.GitCred] = []
        var host = "", token = "", user = ""
        func flush() {
            if !host.isEmpty, !token.isEmpty {
                out.append(.init(host: host.lowercased(),
                                 username: user.isEmpty ? "x-access-token" : user,
                                 token: token))
            }
            token = ""; user = ""
        }
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("#") { continue }
            let indent = line.prefix { $0 == " " || $0 == "\t" }.count
            let body = line.trimmingCharacters(in: .whitespaces)
            guard let colon = body.firstIndex(of: ":") else { continue }
            let key = String(body[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(body[body.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if indent == 0 {
                flush()
                // A bare `host.com:` line starts a block; `key: value` at column
                // 0 in glab's config is a global setting, not a host.
                host = value.isEmpty ? key : ""
                continue
            }
            if tokenKeys.contains(key), !value.isEmpty { token = value }
            if userKeys.contains(key), !value.isEmpty { user = value }
        }
        flush()
        return out
    }
}
