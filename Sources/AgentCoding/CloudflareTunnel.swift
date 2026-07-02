import Crypto
import Foundation
import SandboxEngine
import Security

// MARK: - Cloudflare Tunnel (optional global access for the SSH front door)

/// Pinned cloudflared release. Both constants must be bumped together — the
/// installer refuses to run anything whose archive hash it doesn't know.
/// To bump: download the new cloudflared-darwin-arm64.tgz, `shasum -a 256` it,
/// `codesign -dvv` the extracted binary to confirm the team ID is unchanged,
/// and update `version` + `archiveSHA256` in one commit.
enum CloudflaredPin {
    static let version = "2026.6.1"
    static let archiveSHA256 = "f6d4c439c6c782b83264951d327989ce5e23373acc5942b872411601fedb020d"
    /// Cloudflare Inc.'s Apple Developer Team ID (from the Developer ID
    /// signature on their released binaries).
    static let teamID = "68WVV388M8"

    static var downloadURL: URL {
        URL(string: "https://github.com/cloudflare/cloudflared/releases/download/\(version)/cloudflared-darwin-arm64.tgz")!
    }
}

/// Downloads, verifies, and installs the pinned cloudflared build under
/// ~/Library/Application Support/BromureAC/cloudflared/<version>/.
///
/// Trust model — two independent checks, both must pass:
///  1. SHA256 of the downloaded archive matches the pin (the bytes that run
///     are the exact bytes reviewed when the pin was bumped).
///  2. The extracted Mach-O carries a valid Developer ID signature whose
///     team ID is Cloudflare's (proves Cloudflare built it, independent of
///     the download channel).
/// The GitHub release publishes no checksums, so the pin is our own.
/// Every step is recorded in the supply-chain log.
enum CloudflaredInstaller {

    static var defaultDir: URL {
        ProfileStore().controlSocketURL.deletingLastPathComponent()
            .appendingPathComponent("cloudflared", isDirectory: true)
    }

    enum InstallError: LocalizedError {
        case http(Int)
        case hashMismatch(expected: String, got: String)
        case archiveMissingBinary
        case signature(String)
        case tarFailed(String)
        var errorDescription: String? {
            switch self {
            case .http(let s):
                return "HTTP \(s) downloading cloudflared from GitHub."
            case .hashMismatch(let expected, let got):
                return "cloudflared archive hash mismatch — expected \(expected.prefix(16))…, got \(got.prefix(16))…. "
                    + "Refusing to install. (New release replacing the pinned one, or a tampered download.)"
            case .archiveMissingBinary:
                return "cloudflared archive didn't contain the expected binary."
            case .signature(let m):
                return "cloudflared code-signature verification failed: \(m)"
            case .tarFailed(let m):
                return "Couldn't extract the cloudflared archive: \(m)"
            }
        }
    }

    /// Idempotent: returns immediately if the pinned version is already
    /// installed and still passes signature verification.
    static func ensureInstalled(dir: URL = defaultDir) async throws -> URL {
        let fm = FileManager.default
        let versionDir = dir.appendingPathComponent(CloudflaredPin.version, isDirectory: true)
        let binURL = versionDir.appendingPathComponent("cloudflared")

        if fm.isExecutableFile(atPath: binURL.path),
           (try? verifyDeveloperIDSignature(binURL)) != nil {
            return binURL
        }

        let log = SupplyChainLog.shared
        log.record("[tunnel] downloading cloudflared \(CloudflaredPin.version) (~18 MB) from \(CloudflaredPin.downloadURL.absoluteString)")
        let (tmp, response) = try await URLSession.shared.download(from: CloudflaredPin.downloadURL)
        defer { try? fm.removeItem(at: tmp) }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw InstallError.http(http.statusCode)
        }

        // Check 1: pinned archive hash.
        let archive = try Data(contentsOf: tmp)
        let digest = SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined()
        guard digest == CloudflaredPin.archiveSHA256 else {
            log.record("[tunnel] REFUSED: archive SHA256 \(digest) ≠ pinned \(CloudflaredPin.archiveSHA256).")
            throw InstallError.hashMismatch(expected: CloudflaredPin.archiveSHA256, got: digest)
        }
        log.record("[tunnel] archive SHA256 verified (\(digest.prefix(16))…).")

        // Extract into a staging dir next to the final location (same volume).
        try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o755])
        let staging = dir.appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        try extractTar(archive: tmp, into: staging)

        let extracted = staging.appendingPathComponent("cloudflared")
        guard fm.fileExists(atPath: extracted.path) else { throw InstallError.archiveMissingBinary }
        // URLSession downloads from this (non-LSFileQuarantineEnabled) app
        // aren't quarantined, but strip the xattr anyway in case that changes.
        removexattr(extracted.path, "com.apple.quarantine", 0)

        // Check 2: Developer ID signature chained to Apple's root, with
        // Cloudflare's team ID on the leaf.
        try verifyDeveloperIDSignature(extracted)
        log.record("[tunnel] Developer ID signature verified (Cloudflare Inc., team \(CloudflaredPin.teamID)).")

        try fm.createDirectory(at: versionDir, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o755])
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: extracted.path)
        if fm.fileExists(atPath: binURL.path) { try fm.removeItem(at: binURL) }
        try fm.moveItem(at: extracted, to: binURL)

        // Convenience symlink for humans poking around / future version bumps.
        let current = dir.appendingPathComponent("current")
        try? fm.removeItem(at: current)
        try? fm.createSymbolicLink(at: current, withDestinationURL: binURL)

        log.record("[tunnel] cloudflared \(CloudflaredPin.version) installed at \(binURL.path).")
        return binURL
    }

    private static func extractTar(archive: URL, into dir: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        p.arguments = ["-xzf", archive.path, "-C", dir.path]
        let errPipe = Pipe()
        p.standardError = errPipe
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw InstallError.tarFailed(String(data: errData, encoding: .utf8) ?? "exit \(p.terminationStatus)")
        }
    }

    /// The canonical Developer ID requirement: Apple anchor, the Developer ID
    /// intermediate, a Developer ID leaf, and Cloudflare's team in the OU.
    private static func verifyDeveloperIDSignature(_ binary: URL) throws {
        var staticCode: SecStaticCode?
        var status = SecStaticCodeCreateWithPath(binary as CFURL, [], &staticCode)
        guard status == errSecSuccess, let code = staticCode else {
            throw InstallError.signature("SecStaticCodeCreateWithPath: \(status)")
        }
        let requirementSource = "anchor apple generic"
            + " and certificate 1[field.1.2.840.113635.100.6.2.6]"   // Developer ID intermediate
            + " and certificate leaf[field.1.2.840.113635.100.6.1.13]" // Developer ID Application leaf
            + " and certificate leaf[subject.OU] = \"\(CloudflaredPin.teamID)\""
        var requirement: SecRequirement?
        status = SecRequirementCreateWithString(requirementSource as CFString, [], &requirement)
        guard status == errSecSuccess, let req = requirement else {
            throw InstallError.signature("SecRequirementCreateWithString: \(status)")
        }
        var cfError: Unmanaged<CFError>?
        status = SecStaticCodeCheckValidityWithErrors(code, [], req, &cfError)
        guard status == errSecSuccess else {
            let detail = (cfError?.takeRetainedValue()).map { CFErrorCopyDescription($0) as String }
                ?? "OSStatus \(status)"
            throw InstallError.signature(detail)
        }
    }
}

/// Supervises one `cloudflared` quick-tunnel child process per exposed origin.
///
/// Backs the workspace dashboard's globe buttons: HTTP dev servers in a guest
/// VM get a public `https://<random>.trycloudflare.com` URL. Quick tunnels
/// (no Cloudflare account) carry exactly ONE origin each, so "expose N
/// services" means N independent cloudflared processes. That constraint is
/// also the feature: every service keeps its own random hostname, and
/// exposing/unexposing one never disturbs the others. Hostnames still rotate
/// when their own process dies (reboot, unexpose/re-expose) — on unexpected
/// exit we restart with capped backoff so a rotation is the failure mode, not
/// an outage. HTTP(S) only by design: a quick-tunnel hostname is an HTTPS
/// entry on Cloudflare's edge, so raw-TCP protocols (SSH, databases) would
/// need cloudflared on every connecting client — a different feature (a raw
/// TCP provider like bore/ngrok), not this one.
@Observable
@MainActor
final class CloudflareTunnelSupervisor {

    static let shared = CloudflareTunnelSupervisor()

    enum State: Equatable {
        case installing            // downloading / verifying cloudflared
        case starting              // process up (or retrying), no hostname yet
        case running(hostname: String)
        case failed(String)
    }

    struct Info: Equatable {
        var origin: String         // "ssh://127.0.0.1:2222", "http://192.168.64.5:3000", …
        var state: State
        var hostname: String? {
            if case .running(let h) = state { return h }
            return nil
        }
    }

    /// Observable per-tunnel snapshots (SwiftUI reads these); absence of an id
    /// means that tunnel is stopped. Process bookkeeping lives in the
    /// @ObservationIgnored dicts below.
    private(set) var tunnels: [String: Info] = [:]

    @ObservationIgnored private var procs: [String: Process] = [:]
    /// Per-id, bumped on every expose()/unexpose(); async continuations from a
    /// previous generation (install completion, restart timers, exit handlers)
    /// check it and bail, so an unexpose can't be undone by a stale callback.
    @ObservationIgnored private var generations: [String: Int] = [:]
    @ObservationIgnored private var restartAttempts: [String: Int] = [:]
    /// Shared install: N concurrent expose() calls download cloudflared once.
    @ObservationIgnored private var installTask: Task<URL, Error>?

    /// Written on the main actor; read by the signal-handler and
    /// will-terminate cleanup paths (also main), mirroring InferenceService.
    nonisolated(unsafe) private static var cleanupProcs: [Int32: Process] = [:]
    nonisolated static func killIfRunning() {
        for p in cleanupProcs.values { p.terminate() }
        cleanupProcs.removeAll()
    }

    // MARK: What's exposable

    /// Only services that plausibly speak HTTP get a globe: a quick tunnel to
    /// an SSH daemon or a database wouldn't be reachable with a browser (the
    /// client would need cloudflared), and silently serving 502s helps nobody.
    /// SSH and the well-known raw-TCP protocol ports are excluded; everything
    /// else is treated as a web service (the common case for dev servers in a
    /// workspace).
    nonisolated static func isLikelyWebService(port: Int, process: String) -> Bool {
        if port == 22 || process.contains("sshd") { return false }
        let rawTCPPorts: Set<Int> = [1433, 3306, 3389, 5432, 5672, 5900, 6379, 9092, 11211, 27017]
        return !rawTCPPorts.contains(port)
    }

    // MARK: Lifecycle

    /// Start a tunnel for `origin` under `id`. Asynchronous: returns
    /// immediately; progress is observable via `tunnels[id]`. Idempotent
    /// while healthy: re-exposing the same id+origin is a no-op unless it
    /// failed (so a failed tunnel can be retried); a changed origin restarts
    /// just that tunnel.
    func expose(id: String, origin: String) {
        if let t = tunnels[id], t.origin == origin {
            switch t.state {
            case .failed: break
            case .installing, .starting, .running: return
            }
        }
        unexpose(id, quiet: true)
        generations[id, default: 0] += 1
        let gen = generations[id]!
        tunnels[id] = Info(origin: origin, state: .installing)
        SupplyChainLog.shared.record("[tunnel] exposing \(origin) (\(id))…")
        Task { [weak self] in
            guard let self else { return }
            do {
                let bin = try await self.ensureInstalledOnce()
                guard self.generations[id] == gen else { return }
                self.launch(id: id, origin: origin, bin: bin, gen: gen)
            } catch {
                guard self.generations[id] == gen else { return }
                self.tunnels[id]?.state = .failed(error.localizedDescription)
                SupplyChainLog.shared.record("[tunnel] install failed: \(error.localizedDescription)")
            }
        }
    }

    func unexpose(_ id: String, quiet: Bool = false) {
        generations[id, default: 0] += 1
        restartAttempts[id] = nil
        if let p = procs.removeValue(forKey: id) {
            Self.cleanupProcs[p.processIdentifier] = nil
            p.terminationHandler = nil
            p.terminate()
        }
        if tunnels.removeValue(forKey: id) != nil, !quiet {
            SupplyChainLog.shared.record("[tunnel] \(id) unexposed.")
        }
    }

    /// Tear down every tunnel whose id starts with `prefix` — e.g. all of a
    /// workspace's port exposures when its VM suspends or shuts down.
    func unexposeAll(prefix: String) {
        for id in tunnels.keys where id.hasPrefix(prefix) { unexpose(id) }
    }

    func stopAll() {
        for id in tunnels.keys { unexpose(id) }
    }

    // MARK: Internals

    /// De-dupe concurrent installs; cache success (ensureInstalled re-verifies
    /// the signature on each fresh call anyway, and the task result is the
    /// already-verified path).
    private func ensureInstalledOnce() async throws -> URL {
        if let t = installTask, let url = try? await t.value { return url }
        let t = Task { try await CloudflaredInstaller.ensureInstalled() }
        installTask = t
        do { return try await t.value } catch {
            installTask = nil
            throw error
        }
    }

    private func launch(id: String, origin: String, bin: URL, gen: Int) {
        tunnels[id]?.state = .starting
        let p = Process()
        p.executableURL = bin
        // --no-autoupdate is non-negotiable: cloudflared would otherwise
        // replace the binary we just verified with unverified bytes.
        p.arguments = ["tunnel", "--url", origin, "--no-autoupdate"]

        // cloudflared logs to stderr; the quick-tunnel hostname banner is the
        // only output we need. Funnel both streams through one scanner.
        // (readabilityHandler runs serially on the handle's own queue, hence
        // the @unchecked Sendable box rather than a lock.)
        final class ScanBuffer: @unchecked Sendable { var data = Data() }
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        let scan = ScanBuffer()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            scan.data.append(chunk)
            // Bound the buffer: the banner arrives in the first few KB.
            if scan.data.count > 64 * 1024 { scan.data.removeFirst(scan.data.count - 64 * 1024) }
            guard let text = String(data: scan.data, encoding: .utf8),
                  let host = Self.firstQuickTunnelHostname(in: text) else { return }
            handle.readabilityHandler = nil
            Task { @MainActor [weak self] in
                guard let self, self.generations[id] == gen else { return }
                self.restartAttempts[id] = nil
                self.tunnels[id]?.state = .running(hostname: host)
                SupplyChainLog.shared.record("[tunnel] quick tunnel up: \(host) → \(origin)")
            }
        }

        p.terminationHandler = { proc in
            let status = proc.terminationStatus
            Task { @MainActor [weak self] in
                guard let self, self.generations[id] == gen else { return }
                self.procs[id] = nil
                Self.cleanupProcs[proc.processIdentifier] = nil
                self.scheduleRestart(id: id, origin: origin, afterExit: status, gen: gen)
            }
        }

        do {
            try p.run()
            procs[id] = p
            Self.cleanupProcs[p.processIdentifier] = p
            SupplyChainLog.shared.record("[tunnel] cloudflared started (pid \(p.processIdentifier)) for \(origin).")
        } catch {
            tunnels[id]?.state = .failed("Couldn't launch cloudflared: \(error.localizedDescription)")
            SupplyChainLog.shared.record("[tunnel] launch failed: \(error.localizedDescription)")
        }
    }

    /// Unexpected exit → retry with capped exponential backoff, forever.
    /// (Persistent causes — no network, Cloudflare edge unreachable — heal on
    /// their own; the state string keeps the UI honest meanwhile.)
    private func scheduleRestart(id: String, origin: String, afterExit status: Int32, gen: Int) {
        let attempt = (restartAttempts[id] ?? 0) + 1
        restartAttempts[id] = attempt
        let delay = min(60.0, pow(2.0, Double(min(attempt, 6))))
        tunnels[id]?.state = .starting
        SupplyChainLog.shared.record(
            "[tunnel] cloudflared for \(origin) exited (status \(status)); restarting in \(Int(delay))s "
            + "(attempt \(attempt)). Note: a restart is assigned a NEW trycloudflare.com hostname.")
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, self.generations[id] == gen else { return }
            do {
                let bin = try await self.ensureInstalledOnce()
                guard self.generations[id] == gen else { return }
                self.launch(id: id, origin: origin, bin: bin, gen: gen)
            } catch {
                guard self.generations[id] == gen else { return }
                self.tunnels[id]?.state = .failed(error.localizedDescription)
            }
        }
    }

    /// First `https://<name>.trycloudflare.com` in cloudflared's output.
    nonisolated static func firstQuickTunnelHostname(in text: String) -> String? {
        guard let range = text.range(
            of: #"https://[a-z0-9][a-z0-9-]*\.trycloudflare\.com"#,
            options: .regularExpression) else { return nil }
        return String(text[range].dropFirst("https://".count))
    }
}
