import Foundation
import Testing
@testable import bromure_ac

/// Kimi Code as a first-class agent: the generated guest `.bashrc` must stay
/// valid shell, its Kimi launch path must use the one-shot `--prompt` form
/// (kimi rejects a positional prompt), and the host-side plumbing — fake-key
/// minting, host scoping, tracer classification, tab-icon resolution — must
/// recognize it the way it does the other agents.
@Suite("Kimi Code agent support")
struct KimiAgentTests {

    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kimi-agent-tests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Render the managed `.bashrc` the way a real launch does.
    private func renderBashrc(tool: Profile.Tool) throws -> String {
        let root = try tempDir()
        let store = ProfileStore(rootDir: root)
        let p = Profile(name: "ws", tool: tool, authMode: .token)
        let seedDir = root.appendingPathComponent("seed")
        try store.writeHomeSeedFiles(for: p, into: seedDir, terminalDefaults: .fallback)
        return try String(
            contentsOf: seedDir.appendingPathComponent("files/.bashrc"), encoding: .utf8)
    }

    // MARK: - Guest script

    @Test("Generated .bashrc is valid shell")
    func bashrcParses() throws {
        let rc = try renderBashrc(tool: .kimi)
        let url = try tempDir().appendingPathComponent("bashrc")
        try rc.write(to: url, atomically: true, encoding: .utf8)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-n", url.path]
        let err = Pipe()
        proc.standardError = err
        try proc.run()
        let diagnostics = String(
            data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        proc.waitUntilExit()
        #expect(proc.terminationStatus == 0, "bash -n rejected .bashrc:\n\(diagnostics)")
    }

    @Test("Worktree launcher runs kimi one-shot, never with a positional prompt")
    func kimiLaunchUsesPromptFlag() throws {
        let rc = try renderBashrc(tool: .kimi)
        // kimi errors on `kimi -- "<prompt>"` ("unknown command"), and errors
        // again if --prompt is combined with the yolo/auto flags.
        #expect(rc.contains("\"$_wt_tool\" --prompt=\"$_wt_prompt\""))
        // The generic positional form must still exist for the other agents.
        #expect(rc.contains("\"$_wt_tool\" $_wt_flags -- \"$_wt_prompt\""))
    }

    @Test("Registration VM starts kimi's device-code login, not its TUI")
    func kimiRegistrationUsesLoginSubcommand() throws {
        let rc = try renderBashrc(tool: .kimi)
        #expect(rc.contains("kimi login"))
    }

    @Test("Status reporter ships for every agent, not just the hook-driven ones")
    func statusScriptAlwaysSeeded() throws {
        for tool in Profile.Tool.allCases {
            let root = try tempDir()
            let store = ProfileStore(rootDir: root)
            let p = Profile(name: "ws", tool: tool, authMode: .token)
            let seedDir = root.appendingPathComponent("seed")
            try store.writeHomeSeedFiles(for: p, into: seedDir, terminalDefaults: .fallback)
            #expect(FileManager.default.fileExists(
                atPath: seedDir.appendingPathComponent(
                    "files/.bromure/agent-status.sh").path),
                "\(tool.rawValue) profile is missing agent-status.sh")
        }
    }

    /// Run the `.bashrc`'s Kimi config-merge block the way a boot does:
    /// against a real HOME + meta share, `count` times. Returns the resulting
    /// `~/.kimi-code/config.toml`.
    private func runKimiConfigMerge(existingConfig: String, staged: String,
                                    boots: Int = 1) throws -> String {
        let rc = try renderBashrc(tool: .kimi)
        // Lift the block out of the rendered rc so the test exercises the
        // shipped script, not a copy that can drift from it. Matched by
        // indent depth rather than a literal prefix: Swift's multiline
        // literal strips the closing delimiter's indentation, so the
        // rendered depth isn't the one in the source file.
        let lines = rc.components(separatedBy: "\n")
        func indent(_ s: String) -> Int { s.count - s.drop(while: { $0 == " " }).count }
        guard let open = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces)
                .hasPrefix("if [ -r /mnt/bromure-meta/kimi.toml ]; then")
        }) else { Issue.record("kimi config block not found in .bashrc"); return "" }
        let depth = indent(lines[open])
        guard let close = lines[open...].indices.first(where: { i in
            i > open && lines[i].trimmingCharacters(in: .whitespaces) == "fi"
                && indent(lines[i]) == depth
        }) else { Issue.record("kimi config block is unterminated"); return "" }
        var block = lines[open...close].joined(separator: "\n")

        let root = try tempDir()
        let home = root.appendingPathComponent("home", isDirectory: true)
        let meta = root.appendingPathComponent("meta", isDirectory: true)
        let kimiHome = home.appendingPathComponent(".kimi-code", isDirectory: true)
        try FileManager.default.createDirectory(at: kimiHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: meta, withIntermediateDirectories: true)
        let cfg = kimiHome.appendingPathComponent("config.toml")
        try existingConfig.write(to: cfg, atomically: true, encoding: .utf8)
        try staged.write(to: meta.appendingPathComponent("kimi.toml"),
                         atomically: true, encoding: .utf8)
        // Only the mount point differs from the guest.
        block = block.replacingOccurrences(of: "/mnt/bromure-meta", with: meta.path)

        for _ in 0..<boots {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/bash")
            proc.arguments = ["-c", block]
            proc.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
            try proc.run()
            proc.waitUntilExit()
            #expect(proc.terminationStatus == 0)
        }
        return try String(contentsOf: cfg, encoding: .utf8)
    }

    @Test("Config merge is idempotent and preserves the user's own keys")
    func kimiConfigMergeIdempotent() throws {
        let out = try runKimiConfigMerge(
            existingConfig: "default_model = \"kimi-k2.5\"\n\n[ui]\ntheme = \"dark\"\n",
            staged: SessionDisk.kimiHooksTOML, boots: 4)
        // The user's settings survive…
        #expect(out.contains("default_model = \"kimi-k2.5\""))
        #expect(out.contains("theme = \"dark\""))
        // …and four boots leave exactly one managed block.
        #expect(out.components(separatedBy: "# >>> bromure-kimi").count - 1 == 1)
        #expect(out.components(separatedBy: "event = \"Stop\"").count - 1 == 1)
    }

    @Test("Token-mode merge never leaves a duplicate [providers.kimi] table")
    func kimiConfigMergeDropsDuplicateProvider() throws {
        // A `/login` inside a persistent home writes its own provider table.
        // TOML rejects a duplicate table, so the merge must drop the old one.
        let existing = """
        default_model = "kimi-k2.5"

        [providers.kimi]
        type = "kimi"
        base_url = "https://api.kimi.com/coding/v1"
        api_key = "sk-REAL-USER-KEY"

        [ui]
        theme = "dark"

        """
        let out = try runKimiConfigMerge(
            existingConfig: existing,
            staged: SessionDisk.kimiHooksTOML
                + SessionDisk.kimiTokenProviderTOML(fakeKey: "sk-kimi-brm-fake"),
            boots: 3)
        #expect(out.components(separatedBy: "[providers.kimi]").count - 1 == 1)
        #expect(out.contains("sk-kimi-brm-fake"))
        #expect(!out.contains("sk-REAL-USER-KEY"))
        // Only the provider table is dropped — the rest of the file stands.
        #expect(out.contains("theme = \"dark\""))
        #expect(out.contains("default_model = \"kimi-k2.5\""))
    }

    @Test("Subscription-mode merge keeps the managed provider the seed wrote")
    func kimiConfigMergeKeepsSeededProvider() throws {
        // Subscription mode stages hooks ONLY, so the provider block seeded
        // from the captured registration config must survive the merge.
        let seeded = """
        default_model = "kimi-k2.5"

        [providers.kimi]
        type = "kimi"
        base_url = "https://api.kimi.com/coding/v1"

        """
        let out = try runKimiConfigMerge(existingConfig: seeded,
                                         staged: SessionDisk.kimiHooksTOML, boots: 2)
        #expect(out.contains("[providers.kimi]"))
        #expect(out.contains("base_url = \"https://api.kimi.com/coding/v1\""))
    }

    // MARK: - Guest config

    @Test("Kimi hook config routes every status event to the reporter")
    func kimiHooksTOML() {
        let toml = SessionDisk.kimiHooksTOML
        #expect(toml.contains("event = \"Stop\""))
        #expect(toml.contains("event = \"UserPromptSubmit\""))
        #expect(toml.contains("event = \"PermissionRequest\""))
        #expect(toml.contains("/home/ubuntu/.bromure/agent-status.sh done"))
    }

    @Test("Token-mode provider block carries the fake key, never a real one")
    func kimiProviderTOML() {
        let toml = SessionDisk.kimiTokenProviderTOML(fakeKey: "sk-kimi-brm-abc123")
        #expect(toml.contains("[providers.kimi]"))
        #expect(toml.contains("type = \"kimi\""))
        #expect(toml.contains("base_url = \"https://api.moonshot.ai/v1\""))
        #expect(toml.contains("api_key = \"sk-kimi-brm-abc123\""))
    }

    // MARK: - Host plumbing

    @Test("Token plan mints a Kimi fake scoped to moonshot.ai")
    func kimiTokenPlan() {
        var p = Profile(name: "ws", tool: .kimi, authMode: .token)
        p.apiKey = "sk-real-moonshot-key"
        let plan = p.makeTokenPlan(salt: Data("salt".utf8))
        let fake = plan.fakeForKimi()
        #expect(fake != nil)
        #expect(fake?.hasPrefix("sk-kimi-brm-") == true)
        #expect(fake != "sk-real-moonshot-key")
        // The swap is scoped to the provider's host, so a leak anywhere else
        // trips the compromise detector rather than being substituted.
        let entry = plan.entries.first { if case .moonshotAPIKey = $0.purpose { return true }
                                         else { return false } }
        #expect(entry?.realValue == "sk-real-moonshot-key")
    }

    @Test("Local auth mode points kimi at the MITM inference sentinel")
    func kimiLocalExports() {
        let exports = Profile.Tool.kimi.localEnvExports(model: "some/repo", key: "dummy")
        let byName = Dictionary(uniqueKeysWithValues: exports.map { ($0.name, $0.value) })
        // Provider credentials are config-only in kimi; KIMI_MODEL_* is the
        // one env-driven override it honors.
        #expect(byName["KIMI_MODEL_NAME"] == "some/repo")
        #expect(byName["KIMI_MODEL_API_KEY"] == "dummy")
        #expect(byName["KIMI_MODEL_BASE_URL"]?.contains(InferenceService.localMitmHost) == true)
    }

    @Test("Kimi's cloud hosts are claimed for local routing")
    func kimiLocalProviderHosts() {
        var p = Profile(name: "ws", tool: .kimi, authMode: .local)
        p.activeModelID = "some/repo"
        #expect(p.localProviderCloudHosts.contains("moonshot.ai"))
        #expect(p.localProviderCloudHosts.contains("kimi.com"))
    }

    @Test("Session tracer captures bodies for both Kimi backends")
    func tracerCapturesKimi() {
        #expect(TraceLevel.aiDetails.capturesBodyForHost("api.moonshot.ai"))
        #expect(TraceLevel.aiDetails.capturesBodyForHost("api.kimi.com"))
        // …and only at the AI level or above.
        #expect(!TraceLevel.activity.capturesBodyForHost("api.kimi.com"))
    }

    @Test("MOONSHOT_API_KEY imports as the Kimi tool key")
    func envImportRecognizesKimi() {
        #expect(EnvFileImport.slot(forName: "MOONSHOT_API_KEY") == .toolKey(.kimi))
        #expect(EnvFileImport.hosts(for: .toolKey(.kimi)).contains("moonshot.ai"))
    }

    // MARK: - Tab identity

    @Test("Truncated and full kimi process names resolve to the kimi icon")
    func agentKindResolvesKimiAliases() {
        // What the guest actually reports for the foreground program, plus
        // the spellings the binary and the OSC-2 title marker can take.
        for label in ["kimi", "kimi-co", "kimi-code", "/usr/local/bin/kimi-code",
                      "Port the auth flow (kimi-co)"] {
            #expect(BromureIcons.agentKind(forLabel: label) == "kimi",
                    "\(label) did not resolve to kimi")
        }
        // A shell is still a shell.
        #expect(BromureIcons.agentKind(forLabel: "bash") == nil)
    }

    @Test("Only hook-driven agents may complete an automation run")
    func doneSignalCapability() {
        #expect(Profile.Tool.claude.hasReliableDoneSignal)
        #expect(Profile.Tool.kimi.hasReliableDoneSignal)
        #expect(!Profile.Tool.codex.hasReliableDoneSignal)
        #expect(!Profile.Tool.grok.hasReliableDoneSignal)
    }

    // MARK: - International region (kimi.ai, not the China-only kimi.com)

    @Test("Kimi runs against the international region hosts")
    func regionIsInternational() {
        #expect(KimiRegion.oauthHost == "auth.kimi.ai")
        #expect(KimiRegion.baseURL == "https://api.kimi.ai/coding/v1")
        #expect(KimiRegion.tokenURL.absoluteString == "https://auth.kimi.ai/api/oauth/token")
        // The proxy bearer swap must recognize the international API host AND
        // the legacy China one (a credential registered before the switch) —
        // and ONLY those: a suffix match leaked the real token into the CLI's
        // telemetry-logs.kimi.ai posts.
        #expect(KimiRegion.isSubscriptionHost("api.kimi.ai"))
        #expect(KimiRegion.isSubscriptionHost("api.kimi.com"))
        #expect(!KimiRegion.isSubscriptionHost("kimi.ai"))
        #expect(!KimiRegion.isSubscriptionHost("telemetry-logs.kimi.ai"))
        #expect(!KimiRegion.isSubscriptionHost("auth.kimi.ai"))
        #expect(!KimiRegion.isSubscriptionHost("kimi.example.com"))
        #expect(!KimiRegion.isSubscriptionHost("api.moonshot.ai"))
    }

    @Test("The registration VM's staged proxy.env carries the region override")
    @MainActor
    func registrationStagesRegionEnvEndToEnd() throws {
        // Reproduce the registration coordinator's staging: a scratch Kimi
        // subscription profile, registrationMode, mitmAssets set — then read
        // the meta-share proxy.env the guest sources before `kimi login`.
        let root = try tempDir()
        let store = ProfileStore(rootDir: root)
        let scratch = Profile(name: "Register with Kimi", tool: .kimi,
                              authMode: .subscription, homeModel: .virtiofs)
        try store.save(scratch)
        let disk = SessionDisk(profile: scratch, store: store,
                               baseDiskURL: root.appendingPathComponent("base.img"))
        disk.registrationMode = true
        // A dummy bridge script — prepareMetadataShare copies it; the content
        // is irrelevant to proxy.env.
        let bridge = root.appendingPathComponent("bridge.py")
        try "print('x')".write(to: bridge, atomically: true, encoding: .utf8)
        disk.mitmAssets = SessionDisk.MitmSessionAssets(
            caCertificatePEM: "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----",
            bridgeScriptURL: bridge)
        let share = try disk.prepareMetadataShare()
        let proxyEnv = try String(contentsOf: share.appendingPathComponent("proxy.env"),
                                  encoding: .utf8)
        #expect(proxyEnv.contains("export KIMI_CODE_OAUTH_HOST=https://auth.kimi.ai"))
        #expect(proxyEnv.contains("export KIMI_CODE_BASE_URL=https://api.kimi.ai/coding/v1"))
    }

    @Test("A Kimi subscription stages the global-region env for the guest CLI")
    func subscriptionStagesRegionEnv() {
        // The proxy.env exports force the CLI's `global` region so `kimi login`
        // and the managed API hit kimi.ai; token (moonshot) mode does not.
        let sub = SessionDisk.kimiRegionEnvExports(
            for: Profile(name: "ws", tool: .kimi, authMode: .subscription))
        #expect(sub.contains("export KIMI_CODE_OAUTH_HOST=https://auth.kimi.ai"))
        #expect(sub.contains("export KIMI_CODE_BASE_URL=https://api.kimi.ai/coding/v1"))

        let token = SessionDisk.kimiRegionEnvExports(
            for: Profile(name: "ws", tool: .kimi, authMode: .token))
        #expect(token.isEmpty)

        // A workspace with no Kimi agent stages nothing.
        let claude = SessionDisk.kimiRegionEnvExports(
            for: Profile(name: "ws", tool: .claude, authMode: .subscription))
        #expect(claude.isEmpty)
    }

    // MARK: - Stand-in refresh (kimi 2.0.x forces a refresh on a provisioning 401)

    @Test("The stand-in REFRESH token is deterministic per profile — the proxy matches on it")
    func standInRefreshDeterministic() {
        let pid = UUID()
        let realJWT = "eyJhbGciOiJFUzI1NiJ9.eyJzdWIiOiJ1IiwiZXhwIjoxNzAwMDAwMDAwfQ.sig"
        // The refresh stand-in is what the proxy compares the guest's
        // `grant_type=refresh_token` body against, so two derivations from the
        // same real token + profile MUST agree byte-for-byte.
        let r1 = KimiStandIn.refresh(realRefresh: "real-refresh-token-value", profileID: pid)
        let r2 = KimiStandIn.refresh(realRefresh: "real-refresh-token-value", profileID: pid)
        #expect(r1 == r2)
        #expect(r1 != "real-refresh-token-value")
        #expect(r1.hasPrefix("kimirt-brm-"))
        // A different workspace gets a different stand-in (the proxy scopes
        // the match to the profile the connection belongs to).
        #expect(KimiStandIn.refresh(realRefresh: "real-refresh-token-value", profileID: UUID()) != r1)
        // The access stand-in need not be byte-stable across mints (its JWT
        // payload is re-encoded each time); it only has to be a fake, since
        // whoever mints it registers that exact string for the bearer swap.
        let a = KimiStandIn.access(realAccess: realJWT, profileID: pid)
        #expect(a != realJWT)
        #expect(SubscriptionFakeMint.isJWTFake(a))
    }

    @Test("Proxy's refresh answer satisfies kimi's tokenFromResponse and stays a stand-in")
    func refreshAnswerShape() throws {
        let pid = UUID()
        let record = KimiSubscriptionRecord(
            accessToken: "eyJhbGciOiJFUzI1NiJ9.eyJzdWIiOiJ1IiwiZXhwIjoxNzAwMDAwMDAwfQ.sig",
            refreshToken: "real-refresh-token-value", expiresAt: Date(), savedAt: Date(),
            templateJSON: try JSONSerialization.data(withJSONObject: ["scope": "kimi-code", "token_type": "Bearer"]))
        let out = KimiRefreshAnswer.build(record: record, profileID: pid)
        // kimi's parser: non-empty access_token + refresh_token, finite expires_in > 0.
        let access = try #require(out.json["access_token"] as? String)
        let refresh = try #require(out.json["refresh_token"] as? String)
        let expiresIn = try #require(out.json["expires_in"] as? Int)
        #expect(!access.isEmpty && !refresh.isEmpty && expiresIn > 0)
        // Never the real credential; the same stand-in refresh the seed wrote,
        // so the guest's stored token keeps matching what the proxy recognizes.
        #expect(access != record.accessToken)
        #expect(refresh == KimiStandIn.refresh(realRefresh: record.refreshToken, profileID: pid))
        #expect(access == out.bogusAccess)
        #expect(out.json["scope"] as? String == "kimi-code")
        #expect(out.json["token_type"] as? String == "Bearer")
    }

    // MARK: - Registration capture waits for the provisioned config

    @Test("Registration capture holds until kimi login has written the managed provider")
    @MainActor
    func captureWaitsForProvisionedConfig() throws {
        let home = try tempDir()
        let cred = home.appendingPathComponent("credentials", isDirectory: true)
        try FileManager.default.createDirectory(at: cred, withIntermediateDirectories: true)
        try #"{"access_token":"eyJreal","refresh_token":"rt","expires_at":1,"scope":"kimi-code","token_type":"Bearer","expires_in":900}"#
            .write(to: cred.appendingPathComponent("kimi-code-env-0e4f99c69cc27850.json"),
                   atomically: true, encoding: .utf8)
        let cfg = home.appendingPathComponent("config.toml")

        // Credential present, no config yet (login still provisioning) → keep waiting.
        #expect(ACAppDelegate.readKimiCredentials(in: home) == nil)
        // Hooks-only config (what the guest merge creates) → still not provisioned.
        try "# >>> bromure-kimi\n[[hooks]]\nevent = \"Stop\"\n# <<< bromure-kimi\n"
            .write(to: cfg, atomically: true, encoding: .utf8)
        #expect(ACAppDelegate.readKimiCredentials(in: home) == nil)
        // The managed provider landed → capture, carrying that config and the slot name.
        try "[providers.\"managed:kimi-code\"]\ntype = \"kimi-code\"\n[models.\"kimi-code/k3\"]\nprovider = \"managed:kimi-code\"\n"
            .write(to: cfg, atomically: true, encoding: .utf8)
        let got = try #require(ACAppDelegate.readKimiCredentials(in: home))
        #expect(got.name == "kimi-code-env-0e4f99c69cc27850")
        #expect(got.access == "eyJreal")
        #expect(got.configTOML?.contains("managed:kimi-code") == true)
    }
}
