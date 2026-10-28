import Foundation
import Testing
@testable import bromure_ac

/// Board task "Auto-restore on start": the quit confirmation offers to bring
/// the running workspaces and their sessions back at the next start; that
/// start restores once, never again if it dies on the way.
@Suite("Restore at next start")
struct LaunchRestoreTests {
    private static func tmpURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("restore-\(UUID().uuidString)").appendingPathComponent("restore-at-launch.json")
    }
    private static func src(_ path: String) throws -> String {
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: top.appendingPathComponent(path), encoding: .utf8)
    }

    @Test("the plan keeps each running workspace's open sessions, in tab order")
    func plan() {
        let a = UUID(), b = UUID(), off = UUID()
        func s(_ p: UUID, tab: Int?, alive: Bool? = true, archived: Bool = false) -> AgentSession {
            var x = AgentSession(profileID: p, tool: .claude, title: "t", windowIndex: tab)
            x.agentAlive = alive
            if archived { x.archivedAt = Date() }
            return x
        }
        let s2 = s(a, tab: 2), s1 = s(a, tab: 1), unknown = s(a, tab: 3, alive: nil)
        let sessions = [s2, s1, unknown,
                        s(a, tab: nil),                 // no tab: ended
                        s(a, tab: 4, alive: false),     // its agent exited
                        s(a, tab: 5, archived: true),   // put away
                        s(off, tab: 1)]                 // workspace not running
        let plan = LaunchRestorePlan.make(running: [(id: a, name: "A"), (id: b, name: "B")], sessions: sessions)
        #expect(plan.workspaces.map(\.profileID) == [a, b])
        #expect(plan.workspaces[0].sessions == [s1.id, s2.id, unknown.id])
        #expect(plan.workspaces[1].sessions.isEmpty)
    }

    @Test("a plan is taken once: the start that reads it removes it before anything boots")
    func takenOnce() throws {
        let url = Self.tmpURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let plan = LaunchRestorePlan(savedAt: Date(), workspaces: [.init(profileID: UUID(), name: "A", sessions: [UUID()])])
        LaunchRestorePlan.save(plan, to: url)
        let taken = try #require(LaunchRestorePlan.take(from: url))
        #expect(taken.workspaces == plan.workspaces)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        // The start died while restoring and came back: nothing to restore.
        #expect(LaunchRestorePlan.take(from: url) == nil)
    }

    @Test("an old, empty or unreadable plan is dropped, not restored")
    func dropped() throws {
        let url = Self.tmpURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        LaunchRestorePlan.save(LaunchRestorePlan(savedAt: Date().addingTimeInterval(-LaunchRestorePlan.maxAge - 60),
                                                 workspaces: [.init(profileID: UUID(), name: "A", sessions: [])]), to: url)
        #expect(LaunchRestorePlan.take(from: url) == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        LaunchRestorePlan.save(LaunchRestorePlan(savedAt: Date(), workspaces: []), to: url)
        #expect(LaunchRestorePlan.take(from: url) == nil)
        try Data("{".utf8).write(to: url)
        #expect(LaunchRestorePlan.take(from: url) == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("the quit confirmation asks, and only a quit that happens writes the plan")
    func quitWiring() throws {
        let ac = try Self.src("Sources/AgentCoding/BromureAC.swift")
        let confirm = try #require(ac.range(of: "private func confirmQuit() -> Bool {"))
        let body = ac[confirm.upperBound...].prefix(6000)
        #expect(body.contains("alert.accessoryView = restoreBox"))
        #expect(body.contains("restorePlanAtQuit = restore ? LaunchRestorePlan.make("))
        let will = try #require(ac.range(of: "func applicationWillTerminate(_ notification: Notification) {"))
        #expect(ac[will.upperBound...].prefix(600).contains("LaunchRestorePlan.save(plan)"))
        #expect(ac.contains("self?.restoreAtLaunch()"))
        // Taken (removed) before the first boot.
        let r = try Self.src("Sources/AgentCoding/LaunchRestore.swift")
        let fn = try #require(r.range(of: "@MainActor func restoreAtLaunch("))
        let take = try #require(r[fn.upperBound...].range(of: "LaunchRestorePlan.take(from: planURL)"))
        let boot = try #require(r[fn.upperBound...].range(of: "ensureUp(w.profileID, quietly: true)"))
        #expect(take.lowerBound < boot.lowerBound)
    }

    @Test("the new strings are in every locale")
    func localized() throws {
        for loc in ["en", "fr", "de", "es", "pt", "ja", "zh-Hans", "zh-Hant"] {
            let s = try Self.src("Sources/AgentCoding/\(loc).lproj/Localizable.strings")
            for key in ["Restore these workspaces and their sessions at next start", "Restoring your workspaces",
                        "Restoring Workspaces", "Stop Restoring", "Starting “%@”…", "%1$d of %2$d",
                        "1 session", "%d sessions", "did not start in time"] {
                #expect(s.contains("\n\"\(key)\" = "), "\(loc): \(key)")
            }
        }
    }
}

/// Board task "Auto-restore on start", part 2: loading a detector model
/// (seconds) froze the app. It ran on the shared async threads; it now has
/// a queue of its own, and the proxy answers 503 while it loads instead of
/// holding the request.
@Suite("Detector model loading")
struct DetectorLoadingTests {
    @Test("load and inference run on the detector's own queue, not the shared pool")
    func ownQueue() async {
        let c = PromptInjectionClassifier(modelDirName: "zz-none-\(UUID().uuidString)", logLabel: "t")
        #expect(await c.queueLabel() == "io.bromure.classifier.t")
        #expect(await PIIDetector.shared.queueLabel() == "io.bromure.classifier.pii")
    }

    @Test("readiness never waits: absent without a model, loading while it loads, then settled")
    func readiness() async throws {
        let none = PromptInjectionClassifier(modelDirName: "zz-none-\(UUID().uuidString)", logLabel: "t")
        #expect(await none.readiness() == .absent)

        // A model file that won't load: "loading" at once, then absent.
        let name = "zz-test-\(UUID().uuidString)"
        let c = PromptInjectionClassifier(modelDirName: name, logLabel: "t2")
        let dir = await c.modelDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("not a model".utf8).write(to: dir.appendingPathComponent("model.onnx"))
        try Data("{}".utf8).write(to: dir.appendingPathComponent("tokenizer.json"))
        #expect(await c.readiness() == .loading)
        var settled = ModelReadiness.loading
        for _ in 0..<200 where settled == .loading {
            try await Task.sleep(nanoseconds: 20_000_000)
            settled = await c.readiness()
        }
        #expect(settled == .absent)
        #expect(await c.detect(spans: [(id: nil, content: "x")]) == nil)
    }

    @Test("a load that runs long stops answering 503: the request waits for it")
    func grace() {
        let t = Date()
        #expect(ModelReadiness.loading(since: t, now: t.addingTimeInterval(5)) == .loading)
        #expect(ModelReadiness.loading(since: t, now: t.addingTimeInterval(ModelReadiness.warmupGrace + 1)) == .loadingLong)
        let both = PromptInjectionPolicy(detectSourceInjection: true, detectRulesInjection: true, onDetection: .block)
        #expect(HTTPMitmConnection.warmingDetectors(injection: both, source: .loadingLong, rules: .loadingLong).isEmpty)
    }

    @Test("an enforcing policy waits on the detectors it uses; log mode on none")
    func warming() {
        let both = PromptInjectionPolicy(detectSourceInjection: true, detectRulesInjection: true, onDetection: .block)
        #expect(HTTPMitmConnection.warmingDetectors(injection: both, source: .loading, rules: .ready)
                == ["prompt-injection detection"])
        #expect(HTTPMitmConnection.warmingDetectors(injection: both, source: .loading, rules: .loading).count == 2)
        #expect(HTTPMitmConnection.warmingDetectors(injection: both, source: .absent, rules: .ready).isEmpty)
        var log = both; log.onDetection = .log
        #expect(HTTPMitmConnection.warmingDetectors(injection: log, source: .loading, rules: .loading).isEmpty)
        let rulesOnly = PromptInjectionPolicy(detectRulesInjection: true, onDetection: .ask)
        #expect(HTTPMitmConnection.warmingDetectors(injection: rulesOnly, source: .loading, rules: .ready).isEmpty)
    }

    @Test("the answer is a retryable 503 that says nothing was sent")
    func response() {
        let r = String(decoding: HTTPMitmConnection.detectorWarmingResponse(["PII protection"]), as: UTF8.self)
        #expect(r.hasPrefix("HTTP/1.1 503 Service Unavailable\r\n"))
        #expect(r.contains("\r\nRetry-After: 2\r\n"))
        #expect(r.contains("PII protection model"))
        let body = r.components(separatedBy: "\r\n\r\n")[1]
        #expect(r.contains("Content-Length: \(body.utf8.count)\r\n"))
    }

    @Test("the proxy asks before scanning, for both injection and PII")
    func wired() throws {
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let p = try String(contentsOf: top.appendingPathComponent("Sources/AgentCoding/Mitm/HTTPProxy.swift"), encoding: .utf8)
        let gate = try #require(p.range(of: "await PromptInjectionClassifier.shared.readiness()"))
        let scan = try #require(p.range(of: "if let f = await Self.detectPromptInjection(in: conv, policy: pi) {"))
        #expect(gate.lowerBound < scan.lowerBound)
        let piiGate = try #require(p.range(of: "if await PIIDetector.shared.readiness() == .loading {"))
        let piiScan = try #require(p.range(of: "let outcome = await PIIRewriter.rewriteRequest(body, policy: pii, vault: vault)"))
        #expect(piiGate.lowerBound < piiScan.lowerBound)
    }
}

extension PromptInjectionClassifier {
    func queueLabel() -> String { String(cString: __dispatch_queue_get_label(nil)) }
}
extension PIIDetector {
    func queueLabel() -> String { String(cString: __dispatch_queue_get_label(nil)) }
}
