import Foundation
import Testing
@testable import bromure_ac

/// 5.2.3 crash (EXC_BAD_ACCESS in swift_task_isMainExecutorImpl, from a
/// timer's MainActor.assumeIsolated): an Objective-C exception thrown inside
/// a main-actor task was caught by AppKit's run loop, which left the
/// concurrency runtime's executor record dangling — reproduced with a tiny
/// app (raise in `Task { @MainActor in }`, then any assumeIsolated: SIGSEGV).
/// BromureApplication stops the app at such an exception; one thrown by
/// plain event handling (no Swift job) is survived, as before. These are
/// the two stacks as the repro recorded them.
@Suite("App: an exception that crossed a Swift task is told apart")
struct BromureApplicationTests {
    @Test("a main-actor task's exception crossed a Swift job; a plain timer's didn't")
    func crossedSwiftJob() {
        let inTask = [
            "0   CoreFoundation                      0x000000018216f1f0 __exceptionPreprocess + 176",
            "1   libobjc.A.dylib                     0x0000000181bea91c objc_exception_throw + 88",
            "3   repro                               0x0000000100121590 $s5reproyyScMYcXEfU_yyYaScMYccfU_TY0_ + 132",
            "7   libswift_Concurrency.dylib          0x000000028775fec5 _ZL23completeTaskWithClosurePN5swift12AsyncContextEPNS_10SwiftErrorE + 1",
        ]
        let inTimer = [
            "0   CoreFoundation                      0x000000018216f1f0 __exceptionPreprocess + 176",
            "1   libobjc.A.dylib                     0x0000000181bea91c objc_exception_throw + 88",
            "3   repro                               0x0000000100121590 closure #1 in closure #1 in main + 60",
            "4   Foundation                          0x0000000186b7c420 __NSFireTimer + 104",
            "5   CoreFoundation                      0x00000001854588cc __CFRUNLOOP_IS_CALLING_OUT_TO_A_TIMER_CALLBACK_FUNCTION__ + 32",
        ]
        #expect(BromureApplication.crossedSwiftJob(inTask))
        #expect(!BromureApplication.crossedSwiftJob(inTimer))
        #expect(BromureApplication.crossedSwiftJob(["2 libswift_Concurrency.dylib 0x1 swift_job_run + 76"]))
    }

    @Test("it stops a fat client, never a Mac running its own VMs")
    func stopsOnlyWithoutLocalVMs() {
        #expect(BromureApplication.stopsApp(crossedSwiftJob: true, hostsVMs: false))
        #expect(!BromureApplication.stopsApp(crossedSwiftJob: true, hostsVMs: true))
        #expect(!BromureApplication.stopsApp(crossedSwiftJob: false, hostsVMs: false))
        #expect(!BromureApplication.stopsApp(crossedSwiftJob: false, hostsVMs: true))
    }

    @Test("a sandbox that was never started doesn't count as a live VM")
    @MainActor func idleSandboxIsNotLive() {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sandbox = UbuntuSandboxVM(imageManager: UbuntuImageManager(storageDir: tmp, setupDir: tmp))
        #expect(sandbox.state == .created)
        #expect(!UbuntuSandboxVM.anyLive)
    }
}

/// The exception behind the 5.2.3 crash: a browser_evaluate whose page
/// value was a bare number/bool/null. jsonString checked it would be valid
/// wrapped in an array, then wrote it unwrapped without .fragmentsAllowed —
/// NSInvalidArgumentException, which `try?` doesn't catch.
@Suite("Browser MCP: an evaluate's bare value is written, not thrown")
struct BrowserMCPJSONStringTests {
    @Test("scalars, null, collections and strings all come back as text")
    func scalars() {
        #expect(BrowserMCPServer.jsonString(42) == "42")
        #expect(BrowserMCPServer.jsonString(3.5) == "3.5")
        #expect(BrowserMCPServer.jsonString(true) == "true")
        #expect(BrowserMCPServer.jsonString(NSNull()) == "null")
        #expect(BrowserMCPServer.jsonString("plain") == "plain")
        #expect(BrowserMCPServer.jsonString([1, 2]) == "[1,2]")
        #expect(BrowserMCPServer.jsonString(["a": 1]) == "{\"a\":1}")
        // Not JSON at all: described, never thrown.
        #expect(!BrowserMCPServer.jsonString(Double.nan).isEmpty)
    }
}
