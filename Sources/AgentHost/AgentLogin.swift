import Foundation

/// An agent's account sign-in, run headless on this Mac for a client that
/// isn't in front of it: each CLI's device-code login (Claude's paste-code
/// one), under a pty, with the browser blocked, its link and one-time code
/// scraped for the client to show. The credential lands where the agent
/// itself keeps it — Sidecar never sees or stores it.
final class AgentLogin: @unchecked Sendable {
    static let shared = AgentLogin()

    struct Login {
        var tool: String
        var phase = "starting"          // starting · waiting · done · failed
        var url: String?
        var code: String?
        var needsPaste = false
        var message: String?
        var output = ""
        var startedAt = Date()
        var process: Process?
        var input: FileHandle?

        var json: [String: Any] {
            var d: [String: Any] = ["tool": tool, "phase": phase, "needsPaste": needsPaste,
                                    "startedAt": startedAt.timeIntervalSince1970]
            if let url { d["url"] = url }
            if let code { d["code"] = code }
            if let message { d["message"] = message }
            return d
        }
    }

    private let lock = NSLock()
    private var logins: [String: Login] = [:]

    /// Each CLI's headless login. Claude has no device flow: its page shows
    /// a code the user pastes back. Kimi: the international region.
    static func command(for tool: String) -> (cmd: String, paste: Bool)? {
        switch tool {
        case "claude": return ("claude auth login --claudeai", true)
        case "codex": return ("codex login --device-auth", false)
        case "grok": return ("grok login --device-auth", false)
        case "kimi": return ("kimi login --region global", false)
        default: return nil
        }
    }

    func state(_ tool: String) -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return logins[tool]?.json ?? ["tool": tool, "phase": "idle"]
    }

    /// Start (or rejoin) `tool`'s sign-in; its state.
    func start(_ tool: String) -> Result<[String: Any], HostError> {
        guard let (cmd, paste) = Self.command(for: tool) else {
            return .failure(.notSupported(tool == "omp"
                ? "Oh My Pi uses an API key, not an account: run `omp` in the session's terminal and follow its setup."
                : "\(tool) has no sign-in Bromure can run"))
        }
        lock.lock()
        if let l = logins[tool], l.phase == "starting" || l.phase == "waiting" {
            lock.unlock()
            return .success(l.json)
        }
        var login = Login(tool: tool)
        login.needsPaste = paste
        logins[tool] = login
        lock.unlock()

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        // A pty (the CLIs draw with Ink/ratatui and want one), wide enough
        // that a long URL is never wrapped; `open` shadowed so no browser
        // pops up on this Mac's screen for a user who isn't here.
        let sh = Tmux.userShell
        let inner = "stty cols 4000 rows 50 2>/dev/null; export PATH=\(shellQuote(Self.noBrowserDir())):\"$PATH\" BROWSER=true; exec \(cmd)"
        p.arguments = ["-q", "/dev/null", sh, "-l", "-i", "-c", inner]
        var env = HostEnvironment.forCommands()
        env["NO_COLOR"] = "1"
        p.environment = env
        p.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        let out = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = inp     // held open: an EOF would end the login
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else { h.readabilityHandler = nil; return }
            self?.absorb(tool, String(decoding: data, as: UTF8.self))
        }
        p.terminationHandler = { [weak self] proc in
            self?.finish(tool, status: proc.terminationStatus)
        }
        do { try p.run() } catch {
            update(tool) { $0.phase = "failed"; $0.message = "Couldn't start \(cmd): \(error.localizedDescription)" }
            return .success(state(tool))
        }
        update(tool) { $0.process = p; $0.input = inp.fileHandleForWriting }
        AgentHostLog.log("login: \(tool) sign-in started")
        // Device codes last 15–30 minutes; nobody waits longer.
        DispatchQueue.global().asyncAfter(deadline: .now() + 30 * 60) { [weak self] in
            self?.cancel(tool, reason: "The sign-in timed out.")
        }
        return .success(state(tool))
    }

    /// Claude's pasted code, typed into its prompt.
    func submit(_ tool: String, code: String) -> Result<[String: Any], HostError> {
        let c = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty, c.count < 4096, !c.contains("\n") else { return .failure(.bad("code required")) }
        lock.lock()
        let input = logins[tool]?.input
        lock.unlock()
        guard let input else { return .failure(.bad("no sign-in under way")) }
        try? input.write(contentsOf: Data((c + "\r").utf8))
        return .success(state(tool))
    }

    func cancel(_ tool: String, reason: String = "The sign-in was cancelled.") {
        lock.lock()
        let p = logins[tool]?.process
        let live = logins[tool].map { $0.phase == "starting" || $0.phase == "waiting" } ?? false
        if live { logins[tool]?.phase = "failed"; logins[tool]?.message = reason }
        lock.unlock()
        if live, let p, p.isRunning { p.terminate() }
    }

    // MARK: Output

    private func update(_ tool: String, _ change: (inout Login) -> Void) {
        lock.lock(); defer { lock.unlock() }
        if var l = logins[tool] { change(&l); logins[tool] = l }
    }

    private func absorb(_ tool: String, _ chunk: String) {
        update(tool) { l in
            l.output += chunk
            if l.output.count > 64_000 { l.output = String(l.output.suffix(32_000)) }
            let text = Self.plain(l.output)
            if l.url == nil, let u = Self.link(in: text) { l.url = u }
            if l.code == nil, !l.needsPaste, let c = Self.userCode(in: text, url: l.url) { l.code = c }
            if l.phase == "starting", l.url != nil, l.needsPaste || l.code != nil { l.phase = "waiting" }
        }
    }

    private func finish(_ tool: String, status: Int32) {
        update(tool) { l in
            l.input = nil
            l.process = nil
            guard l.phase == "starting" || l.phase == "waiting" else { return }
            if status == 0 {
                l.phase = "done"
            } else {
                l.phase = "failed"
                l.message = Self.lastLine(Self.plain(l.output)) ?? "The sign-in didn't complete (exit \(status))."
            }
        }
        AgentHostLog.log("login: \(tool) sign-in ended (\(status))")
    }

    /// Terminal output as text: OSC (hyperlinks, titles) and CSI sequences out.
    static func plain(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{1B}\\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\u{1B}[()][A-Z0-9]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r", with: "")
    }

    /// The first sign-in link the CLI prints (never a localhost callback).
    static func link(in text: String) -> String? {
        let re = try! NSRegularExpression(pattern: #"https://[^\s"'<>\x{1B}]+"#)
        for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let r = Range(m.range, in: text) else { continue }
            var u = String(text[r])
            while let last = u.last, ".,;:)]".contains(last) { u.removeLast() }
            if u.contains("localhost") || u.contains("127.0.0.1") { continue }
            return u
        }
        return nil
    }

    /// The one-time code: `user_code=` in the link, else an `ABCD-EFGH`-shaped
    /// token on its own (Codex prints it on a line of its own).
    static func userCode(in text: String, url: String?) -> String? {
        if let url, let q = URLComponents(string: url)?.queryItems?.first(where: { $0.name == "user_code" })?.value,
           !q.isEmpty { return q }
        let stripped = text.replacingOccurrences(of: #"https://\S+"#, with: "", options: .regularExpression)
        let re = try! NSRegularExpression(pattern: #"\b[A-Z0-9]{4,5}-[A-Z0-9]{4,6}\b"#)
        let ns = stripped as NSString
        return re.firstMatch(in: stripped, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
    }

    static func lastLine(_ text: String) -> String? {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty && $0 != "^D" }
    }

    /// `open` / `xdg-open` that do nothing, first on the login's PATH.
    private static func noBrowserDir() -> String {
        let dir = AgentHostPaths.support.appendingPathComponent("login-bin")
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["open", "xdg-open"] {
            let f = dir.appendingPathComponent(name)
            if !fm.fileExists(atPath: f.path) {
                try? "#!/bin/sh\n# Bromure Sidecar: sign-ins run for a remote client; no browser here.\nexit 0\n"
                    .write(to: f, atomically: true, encoding: .utf8)
                chmod(f.path, 0o755)
            }
        }
        return dir.path
    }
}
