import AppKit
import Combine

/// The coding agents Bromure Sidecar can run, and how each is installed —
/// always by its maker's own installer, into the user's account, on this
/// Mac. Bromure never ships or hosts an agent.
struct AgentSpec: Identifiable, Hashable {
    let id: String          // the command: claude, codex, grok, kimi, omp
    let name: String
    let maker: String
    let blurb: String
    /// The maker's documented one-line installer (it also updates).
    let installCommand: String
    let tint: NSColor
    /// Sessions get live status, chat and delegation (hooks + MCP wired).
    let fullyIntegrated: Bool

    /// Checked against each maker's install docs (2026-09-30). Kimi: the
    /// kimi.ai mirror, whose install marks the `global` region (kimi.com's
    /// marks `mainland-cn`, where international accounts can't sign in).
    static let all: [AgentSpec] = [
        AgentSpec(id: "claude", name: "Claude Code", maker: "Anthropic",
                  blurb: "Anthropic's coding agent. Fully integrated: live status, chat, rooms and delegation.",
                  installCommand: "curl -fsSL https://claude.ai/install.sh | bash",
                  tint: NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1), fullyIntegrated: true),
        AgentSpec(id: "codex", name: "Codex", maker: "OpenAI",
                  blurb: "OpenAI's coding agent for the terminal.",
                  installCommand: "curl -fsSL https://chatgpt.com/codex/install.sh | sh",
                  tint: NSColor(srgbRed: 0.10, green: 0.10, blue: 0.12, alpha: 1), fullyIntegrated: false),
        AgentSpec(id: "grok", name: "Grok Build", maker: "xAI",
                  blurb: "xAI's coding agent harness, a full-screen terminal UI.",
                  installCommand: "curl -fsSL https://x.ai/cli/install.sh | bash",
                  tint: NSColor(srgbRed: 0.25, green: 0.25, blue: 0.28, alpha: 1), fullyIntegrated: false),
        AgentSpec(id: "kimi", name: "Kimi Code", maker: "Moonshot AI",
                  blurb: "Moonshot's coding agent, a single binary (international edition).",
                  installCommand: "curl -fsSL https://code.kimi.ai/kimi-code/install.sh | bash",
                  tint: NSColor(srgbRed: 0.12, green: 0.45, blue: 0.95, alpha: 1), fullyIntegrated: false),
        AgentSpec(id: "omp", name: "Oh My Pi", maker: "Open source",
                  blurb: "A terminal coding agent with an IDE's tools wired in.",
                  installCommand: "curl -fsSL https://omp.sh/install | sh",
                  tint: NSColor(srgbRed: 0.09, green: 0.60, blue: 0.40, alpha: 1), fullyIntegrated: false),
    ]

    static func spec(_ id: String) -> AgentSpec? { all.first { $0.id == id } }

    /// The logo (Bromure AC's art: a template drawing, tinted by the view).
    var logo: NSImage? { Self.resourceImage("agents/\(id).svg") }

    /// A template image from the SwiftPM resource bundle, looked up by hand:
    /// `Bundle.module` traps when the bundle is missing.
    static func resourceImage(_ path: String) -> NSImage? {
        let bundleName = "bromure_bromure-sidecar.bundle"
        let candidates = [Bundle.main.resourceURL, Bundle.main.bundleURL,
                          Bundle.main.executableURL?.deletingLastPathComponent()].compactMap { $0 }
        for base in candidates {
            let url = base.appendingPathComponent(bundleName).appendingPathComponent(path)
            if let img = NSImage(contentsOf: url) { img.isTemplate = true; return img }
        }
        return nil
    }
}

/// What's installed, and installs under way — the Manage Agents window's
/// model, and the session guard's source of truth.
@MainActor
final class AgentInstaller: ObservableObject {
    static let shared = AgentInstaller()

    enum Phase: Equatable {
        /// Before any scan, or while the first one runs.
        case unknown
        /// The last scan didn't finish (the login shell timed out): no verdict.
        case unchecked
        case missing
        case installed(version: String, path: String)
        case queued
        case installing(line: String)
        case failed(String)
    }

    @Published private(set) var phases: [String: Phase] = [:]
    @Published private(set) var scanning = false
    /// The last scan ran to its end (`AgentDetection.Scan.complete`).
    @Published private(set) var lastScanComplete = false
    @Published private(set) var busy = false
    /// Each agent's installer output, for "Show log".
    @Published private(set) var logs: [String: String] = [:]

    /// Where installers put their binaries, beyond the login PATH (a fresh
    /// install isn't on it until the user's shell reloads its profile).
    nonisolated static let extraBins = ["$HOME/.local/bin", "$HOME/.grok/bin", "$HOME/.bun/bin",
                                        "$HOME/.omp/bin", "$HOME/.kimi-code/bin", "$HOME/.kimi/bin", "$HOME/.codex/bin",
                                        "/opt/homebrew/bin", "/usr/local/bin"]

    func phase(_ id: String) -> Phase { phases[id] ?? .unknown }

    /// True only when a complete scan didn't find it (unknown ≠ missing),
    /// and it still isn't in an installer's folder or on the login PATH:
    /// a stale verdict (installed since, or a scan that went wrong) never
    /// refuses a start — it's dropped, and a fresh scan runs.
    /// Read from any thread: session starts run off the main one.
    nonisolated static func isKnownMissing(_ id: String) -> Bool {
        missingLock.lock()
        let listed = knownMissing.contains(id)
        missingLock.unlock()
        guard listed else { return false }
        guard AgentDetection.onDisk([id], dirs: searchDirs(), home: NSHomeDirectory())[id] != nil else { return true }
        missingLock.lock(); knownMissing.remove(id); missingLock.unlock()
        AgentHostLog.log("agents: \(id) found on disk after a scan missed it; rescanning")
        Task { @MainActor in AgentInstaller.shared.scan() }
        return false
    }

    /// Where an agent's binary may be without asking a shell: the
    /// installers' folders, then the login PATH.
    nonisolated static func searchDirs() -> [String] {
        let path = HostEnvironment.forCommands()["PATH"] ?? ""
        return extraBins + path.split(separator: ":").map(String.init)
    }
    nonisolated private static let missingLock = NSLock()
    nonisolated(unsafe) private static var knownMissing: Set<String> = []

    private func publishMissing() {
        let missing = Set(phases.compactMap { $0.value == .missing ? $0.key : nil })
        Self.missingLock.lock(); Self.knownMissing = missing; Self.missingLock.unlock()
    }

    /// Look for every agent through the user's login shell (their PATH, as a
    /// session starts it), plus the installers' own folders.
    func scan() {
        guard !scanning else { return }
        scanning = true
        let ids = AgentSpec.all.map(\.id)
        Task.detached {
            let (found, missing, complete) = Self.detect(ids)
            await MainActor.run {
                for id in ids {
                    switch self.phases[id] {
                    case .installing?, .queued?: continue   // an install owns it
                    default: break
                    }
                    if let (path, version) = found[id] {
                        self.phases[id] = .installed(version: version, path: path)
                    } else if case .failed? = self.phases[id] {
                        continue                          // keep the error visible
                    } else if missing.contains(id) {
                        self.phases[id] = .missing
                    } else {
                        self.phases[id] = .unchecked      // the scan didn't finish: no verdict
                    }
                }
                self.lastScanComplete = complete
                self.scanning = false
                self.publishMissing()
            }
        }
    }

    /// The agents found (path, version) and the ones a complete scan says
    /// aren't there (AgentDetection: a shell killed on its timeout calls
    /// nothing missing; a binary in an installer's folder counts).
    nonisolated static func detect(_ ids: [String]) -> (found: [String: (String, String)], missing: Set<String>, complete: Bool) {
        let r = HostProcess.run(executable: Tmux.userShell,
                                args: ["-l", "-i", "-c", AgentDetection.script(ids, extraBins: extraBins)],
                                env: ["HOME": NSHomeDirectory(), "USER": NSUserName(), "TERM": "dumb",
                                      "LANG": "en_US.UTF-8", "SHELL": Tmux.userShell],
                                timeout: 60)
        let scan = AgentDetection.parse(r.stdout)
        let disk = AgentDetection.onDisk(ids, dirs: searchDirs(), home: NSHomeDirectory())
        if !scan.complete {
            AgentHostLog.log("agents: the login shell's scan didn't finish (status \(r.status)"
                             + (r.timedOut ? ", timed out" : "") + "); nothing is called missing")
        }
        var out: [String: (String, String)] = [:]
        for id in ids {
            if let f = scan.found[id] {
                out[id] = (f.path, f.version.map(versionNumber) ?? "installed")
            } else if let path = disk[id] {
                out[id] = (path, "installed")
            }
        }
        return (out, AgentDetection.missing(ids, scan: scan, onDisk: disk), scan.complete)
    }

    /// "2.1.284 (Claude Code)" / "codex-cli 0.9.1" → the first version-looking
    /// token, else the whole line.
    nonisolated static func versionNumber(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        if let r = t.range(of: #"\d+\.\d+(\.\d+)?([-.+][0-9A-Za-z.]+)?"#, options: .regularExpression) {
            return String(t[r])
        }
        return t.isEmpty ? "installed" : String(t.prefix(24))
    }

    /// Run the chosen agents' installers one after another, in the
    /// background. Each is the maker's own command; nothing is fetched by us.
    func install(_ ids: [String]) {
        let specs = ids.compactMap(AgentSpec.spec)
        guard !specs.isEmpty, !busy else { return }
        busy = true
        for s in specs { phases[s.id] = .queued; logs[s.id] = "" }
        Task.detached {
            for s in specs {
                await MainActor.run { self.phases[s.id] = .installing(line: "Starting…") }
                let ok = Self.runInstaller(s) { line in
                    Task { @MainActor in
                        self.logs[s.id, default: ""] += line + "\n"
                        if case .installing = self.phases[s.id] { self.phases[s.id] = .installing(line: line) }
                    }
                }
                AgentHostLog.log("agents: \(s.id) installer \(ok ? "finished" : "failed")")
                let found = Self.detect([s.id]).found[s.id]
                await MainActor.run {
                    if let (path, version) = found {
                        self.phases[s.id] = .installed(version: version, path: path)
                    } else {
                        let tail = (self.logs[s.id] ?? "").split(separator: "\n").last.map(String.init) ?? ""
                        self.phases[s.id] = .failed(ok ? "Installed, but `\(s.id)` isn't found on your PATH yet." : tail.isEmpty ? "The installer failed." : tail)
                    }
                }
            }
            // Installers add their folder to the shell profile: sessions
            // started from now on get the new PATH.
            HostEnvironment.captureLoginPath()
            await MainActor.run { self.busy = false; self.publishMissing() }
        }
    }

    /// One installer, its output streamed line by line (ANSI stripped).
    nonisolated private static func runInstaller(_ s: AgentSpec, onLine: @escaping @Sendable (String) -> Void) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", "set -o pipefail; " + s.installCommand]
        var env = HostEnvironment.forCommands()
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
        env["TERM"] = "dumb"
        env["NO_COLOR"] = "1"
        env["CI"] = "1"          // installers skip interactive prompts
        p.environment = env
        p.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        p.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        let buffer = LineBuffer()
        pipe.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            guard !data.isEmpty else { return }
            let lines = buffer.append(data)
            for l in lines {
                let clean = l.replacingOccurrences(of: #"\u{1B}\[[0-9;?]*[A-Za-z]"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
                if !clean.isEmpty { onLine(clean) }
            }
        }
        do { try p.run() } catch { onLine("Couldn't start the installer: \(error.localizedDescription)"); return false }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15 * 60, execute: killer)
        p.waitUntilExit()
        killer.cancel()
        pipe.fileHandleForReading.readabilityHandler = nil
        return p.terminationStatus == 0
    }
}

/// Splits a pipe's chunks into lines (\n or \r: installers draw progress
/// bars with carriage returns).
private final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = ""

    func append(_ data: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        pending += String(decoding: data, as: UTF8.self)
        var lines: [String] = []
        while let nl = pending.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
            lines.append(String(pending[..<nl]))
            pending = String(pending[pending.index(after: nl)...])
        }
        return lines
    }
}
