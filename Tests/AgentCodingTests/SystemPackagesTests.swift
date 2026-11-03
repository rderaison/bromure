import Foundation
import Testing
@testable import bromure_ac

@Suite("System packages on request (apt under the sandbox)")
struct SystemPackagesTests {
    final class Calls: @unchecked Sendable {
        var installs: [[String]] = []
        let lock = NSLock()
    }

    private func advisor(on: Bool = true, exit: Int = 0) -> (OpenShellAdvisor, UUID, Calls) {
        let a = OpenShellAdvisor()
        let calls = Calls()
        a.systemPackagesProvider = { _ in on }
        a.installPackages = { _, _, pkgs in
            calls.lock.lock(); calls.installs.append(pkgs); calls.lock.unlock()
            return (exit, "Setting up \(pkgs.joined(separator: " ")) ...")
        }
        return (a, UUID(), calls)
    }

    private func call(_ a: OpenShellAdvisor, _ pid: UUID, _ method: String, _ target: String,
                      _ body: [String: Any]? = nil) async -> (Int, [String: Any]) {
        let data = body.flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data()
        let (status, _, payload) = await a.handle(profileID: pid, method: method, target: target, body: data,
                                                   policyReloaded: { _ in true })
        return (status, (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] ?? [:])
    }

    @Test("Off: the route says so, and nothing is queued")
    func off() async {
        let (a, pid, _) = advisor(on: false)
        let (status, body) = await call(a, pid, "POST", "/v1/packages", ["manager": "apt", "packages": ["cowsay"]])
        #expect(status == 404)
        #expect(body["error"] as? String == "feature_disabled")
        #expect(a.packageRequests(for: pid).isEmpty)
    }

    @Test("Only package names: options, paths and .deb files are refused")
    func names() async {
        let (a, pid, _) = advisor()
        for bad in ["-o", "--allow-unauthenticated", "./evil.deb", "evil.deb", "/tmp/x", "a b", "Foo"] {
            let (status, _) = await call(a, pid, "POST", "/v1/packages", ["manager": "apt", "packages": [bad]])
            #expect(status == 400, "\(bad)")
        }
        #expect(OpenShellAdvisor.isValidPackage("libssl-dev"))
        #expect(OpenShellAdvisor.isValidPackage("g++"))
        #expect(OpenShellAdvisor.isValidPackage("nginx=1.24.0-2ubuntu7"))
        #expect(a.packageRequests(for: pid).isEmpty)
    }

    @Test("Approve: the guest installs exactly those packages, and the waiting shim hears installed")
    func approve() async {
        let (a, pid, calls) = advisor()
        let (status, body) = await call(a, pid, "POST", "/v1/packages", ["manager": "apt", "packages": ["cowsay", "jq"]])
        #expect(status == 202)
        let id = try! #require(body["id"] as? String)
        #expect(body["status"] as? String == "pending")
        // The same request again is the same request.
        let (_, again) = await call(a, pid, "POST", "/v1/packages", ["manager": "apt", "packages": ["cowsay", "jq"]])
        #expect(again["id"] as? String == id)

        async let waited = call(a, pid, "GET", "/v1/packages/\(id)/wait?timeout=10")
        try? await Task.sleep(nanoseconds: 300_000_000)
        await a.approvePackages(id: id, profileID: pid)
        let (_, final) = await waited
        #expect(final["status"] as? String == "installed")
        #expect(final["exit_code"] as? Int == 0)
        #expect((final["output"] as? String)?.contains("cowsay") == true)
        #expect(calls.installs == [["cowsay", "jq"]])
    }

    @Test("Reject: nothing is installed, and the reason travels back")
    func reject() async {
        let (a, pid, calls) = advisor()
        let (_, body) = await call(a, pid, "POST", "/v1/packages", ["manager": "apt", "packages": ["nmap"]])
        let id = try! #require(body["id"] as? String)
        a.rejectPackages(id: id, profileID: pid, reason: "not on this project")
        let (_, final) = await call(a, pid, "GET", "/v1/packages/\(id)")
        #expect(final["status"] as? String == "rejected")
        #expect(final["reason"] as? String == "not on this project")
        #expect(calls.installs.isEmpty)
        // Approving afterwards does nothing.
        await a.approvePackages(id: id, profileID: pid)
        #expect(calls.installs.isEmpty)
    }

    @Test("A failed install reports its exit code")
    func failed() async {
        let (a, pid, _) = advisor(exit: 100)
        let (_, body) = await call(a, pid, "POST", "/v1/packages", ["manager": "apt", "packages": ["doesnotexist"]])
        let id = try! #require(body["id"] as? String)
        await a.approvePackages(id: id, profileID: pid)
        let (_, final) = await call(a, pid, "GET", "/v1/packages/\(id)")
        #expect(final["status"] as? String == "failed")
        #expect(final["exit_code"] as? Int == 100)
    }

    @Test("The switches: only under the OpenShell engine; on by default; saved only when off")
    func switches() throws {
        var p = Profile(name: "t", tool: .claude, authMode: .token)
        #expect(p.sandboxHomePackages && p.sandboxSystemPackages)
        #expect(!p.effectiveSandboxSystemPackages)
        p.networkPolicy = "version: 1\nnetwork_policies: {}\n"
        #expect(p.effectiveSandboxSystemPackages && p.effectiveSandboxHomePackages)
        p.sandboxSystemPackages = false
        let data = try JSONEncoder().encode(p)
        let back = try JSONDecoder().decode(Profile.self, from: data)
        #expect(!back.sandboxSystemPackages && back.sandboxHomePackages)
        #expect(String(decoding: data, as: UTF8.self).contains("sandboxSystemPackages"))
        #expect(!String(decoding: data, as: UTF8.self).contains("sandboxHomePackages"))
    }

    /// Finding (CWE-362): "A second Install click starts another root
    /// apt-get and can overwrite success". The pending check and the
    /// `.installing` write were two lock acquisitions.
    @Test("Two approvals and a reject at once: one apt run, and its result stands")
    func oneInstall() async throws {
        let a = OpenShellAdvisor()
        let calls = Calls()
        a.systemPackagesProvider = { _ in true }
        a.installPackages = { _, _, pkgs in
            calls.lock.lock(); calls.installs.append(pkgs); let n = calls.installs.count; calls.lock.unlock()
            try? await Task.sleep(nanoseconds: 200_000_000)
            return n == 1 ? (0, "installed") : (100, "E: Could not get lock /var/lib/dpkg/lock-frontend")
        }
        let pid = UUID()
        let (status, body) = await call(a, pid, "POST", "/v1/packages", ["manager": "apt", "packages": ["jq"]])
        #expect(status == 202)
        let id = try #require(body["id"] as? String)
        await withTaskGroup(of: Void.self) { g in
            g.addTask { await a.approvePackages(id: id, profileID: pid) }
            g.addTask { await a.approvePackages(id: id, profileID: pid) }
            g.addTask {
                try? await Task.sleep(nanoseconds: 50_000_000)
                a.rejectPackages(id: id, profileID: pid, reason: "too late")
            }
        }
        #expect(calls.installs.count == 1)
        let r = try #require(a.packageRequest(id: id, profileID: pid))
        #expect(r.status == .installed && r.exitCode == 0)
        // Once it left pending, neither a reject nor another approval moves it.
        a.rejectPackages(id: id, profileID: pid, reason: "")
        await a.approvePackages(id: id, profileID: pid)
        #expect(a.packageRequest(id: id, profileID: pid)?.status == .installed && calls.installs.count == 1)
    }

    @Test("Approve from many threads at once (the drawer and the control socket): never two installs")
    func approveRace() async throws {
        let a = OpenShellAdvisor()
        final class Per: @unchecked Sendable { var counts: [String: Int] = [:]; let lock = NSLock() }
        let per = Per()
        a.systemPackagesProvider = { _ in true }
        a.installPackages = { _, _, pkgs in
            per.lock.lock(); per.counts[pkgs[0], default: 0] += 1; per.lock.unlock()
            return (0, "ok")
        }
        let pid = UUID()
        var ids: [String] = []
        for n in 0..<90 {          // the advisor keeps 100 per workspace
            let (_, body) = await call(a, pid, "POST", "/v1/packages", ["manager": "apt", "packages": ["pkg\(n)"]])
            ids.append(try #require(body["id"] as? String))
        }
        // Each request approved from 4 threads released together.
        let all = ids
        DispatchQueue.concurrentPerform(iterations: all.count * 4) { k in
            let id = all[k / 4]
            let done = DispatchSemaphore(value: 0)
            Task.detached { await a.approvePackages(id: id, profileID: pid); done.signal() }
            done.wait()
        }
        let twice = per.counts.filter { $0.value > 1 }
        #expect(twice.isEmpty, "installed more than once: \(twice.count) request(s)")
        #expect(per.counts.count == 90)
    }
}
