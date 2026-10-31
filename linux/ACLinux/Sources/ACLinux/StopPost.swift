import Foundation

/// The unit's ExecStopPost=: with KillMode=process, only the daemon is
/// signalled on stop, so a daemon SIGKILLed past TimeoutStopSec leaves its
/// QEMUs in the cgroup. This ends them when the stop was asked for (a stop or
/// restart job is queued for the unit) or when no automatic restart follows
/// (`$SERVICE_RESULT` success: Restart=on-failure won't restart); after a
/// crash, the restart is coming and its daemon re-adopts them.
// @port-skip linux-only: systemd stop-post sweep (macOS has no service manager stop)
public enum StopPost {
    /// What stop-post saw, from its environment and the manager.
    public struct Facts: Sendable, Equatable {
        public var serviceResult: String
        /// The unit's queued job id; empty when none.
        public var job: String
        // @port-skip linux-only: stop-post facts
        public init(serviceResult: String, job: String) { self.serviceResult = serviceResult; self.job = job }
    }

    /// Kill the leftovers unless a crash restart will re-adopt them.
    // @port-skip linux-only: stop-post decision
    public static func shouldSweep(_ f: Facts) -> Bool {
        let job = f.job.trimmingCharacters(in: .whitespacesAndNewlines)
        return (!job.isEmpty && job != "0") || f.serviceResult == "success"
    }

    /// The cgroup v2 path and unit name of `/proc/self/cgroup`'s `0::` line,
    /// and whether it lives under a user manager.
    // @port-skip linux-only: stop-post cgroup
    public static func ownUnit(_ procSelfCgroup: String) -> (cgroup: String, unit: String, user: Bool)? {
        guard let line = procSelfCgroup.split(separator: "\n").first(where: { $0.hasPrefix("0::") }) else { return nil }
        let path = String(line.dropFirst(3))
        guard let unit = path.split(separator: "/").last, unit.hasSuffix(".service") else { return nil }
        return (path, String(unit), path.contains("/user@"))
    }

    /// The sweep: SIGTERM to every other process in the cgroup, up to `grace`
    /// for them to go, then SIGKILL. Returns a log line.
    // @port-skip linux-only: stop-post sweep
    public static func run(environment: [String: String] = ProcessInfo.processInfo.environment,
                           grace: Duration = .seconds(10)) async -> String {
        guard let cg = try? String(contentsOfFile: "/proc/self/cgroup", encoding: .utf8), let own = ownUnit(cg) else {
            return "stop-post: not in a service cgroup; nothing to do"
        }
        let systemctl = ["/usr/bin/systemctl", "/bin/systemctl"].first { FileManager.default.isExecutableFile(atPath: $0) }
        let job = systemctl.flatMap { exe in
            try? ChildProcess.capture(exe, (own.user ? ["--user"] : []) + ["show", "-p", "Job", "--value", own.unit], input: nil)
        }.map { String(decoding: $0, as: UTF8.self) } ?? ""
        let facts = Facts(serviceResult: environment["SERVICE_RESULT"] ?? "", job: job)
        let what = "SERVICE_RESULT=\(facts.serviceResult) job=\(facts.job.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "none" : facts.job.trimmingCharacters(in: .whitespacesAndNewlines))"
        guard shouldSweep(facts) else { return "stop-post: \(what): a restart follows; leaving the VMs for it to re-adopt" }
        let procs = "/sys/fs/cgroup" + own.cgroup + "/cgroup.procs"
        func others() -> [Int32] {
            ((try? String(contentsOfFile: procs, encoding: .utf8)) ?? "").split(separator: "\n")
                .compactMap { Int32($0) }.filter { $0 != getpid() }
        }
        let first = others()
        guard !first.isEmpty else { return "stop-post: \(what): the cgroup is empty" }
        for pid in first { kill(pid, SIGTERM) }
        let deadline = ContinuousClock.now + grace
        while !others().isEmpty, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(100)) }
        let left = others()
        for pid in left { kill(pid, SIGKILL) }
        return "stop-post: \(what): SIGTERM to \(first.count) process(es)" + (left.isEmpty ? "" : ", SIGKILL to \(left.count)")
    }
}
