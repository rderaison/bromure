#!/usr/bin/env python3
"""Compile the actual Swift retirement routine against controlled VM/resources.

No Virtualization framework or live VM is involved. The 30-second timeout is
NOT shortened or substituted. Requires Swift6; --emit permits source review on
machines without Swift. Invocation failure/timeout is never a test pass.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

PRELUDE = r'''
import Foundation

@MainActor public final class FakeVM {
    public enum State { case stopped, error, starting, pausing, resuming, saving, restoring, running, paused, stopping }
    public var state: State
    public var stopCount = 0
    public var completeStopImmediately = true
    public var stopError = false
    public var pendingCallback: ((Error?) -> Void)?
    public init(_ state: State) { self.state = state }
    public func stop(completionHandler: @escaping (Error?) -> Void) {
        stopCount += 1
        if stopError {
            completionHandler(NSError(domain: "fakeStop", code: 1))
        } else if completeStopImmediately {
            state = .stopped
            completionHandler(nil)
        } else {
            state = .stopping
            pendingCallback = completionHandler
        }
    }
}
@MainActor public final class Counters {
    public var counts: [String: Int] = [:]
    public let vm: FakeVM
    public init(_ vm: FakeVM) { self.vm = vm }
    public func add(_ key: String) {
        precondition(vm.state == .stopped || vm.state == .error, "cleanup in nonterminal state")
        counts[key, default: 0] += 1
    }
}
@MainActor public final class FakeHandle {
    public var readabilityHandler: (() -> Void)?
    let name: String; let counts: Counters
    init(_ name: String, _ counts: Counters) { self.name = name; self.counts = counts }
    public func close() throws { counts.add(name) }
}
@MainActor public final class FakePipe {
    public let fileHandleForReading: FakeHandle
    public let fileHandleForWriting: FakeHandle
    init(_ name: String, _ counts: Counters) {
        fileHandleForReading = FakeHandle(name + "Read", counts)
        fileHandleForWriting = FakeHandle(name + "Write", counts)
    }
}
@MainActor public final class FakeStopper {
    let name: String; let counts: Counters
    init(_ name: String, _ counts: Counters) { self.name = name; self.counts = counts }
    public func stop() { counts.add(name) }
}
@MainActor public final class FakeDisk {
    let counts: Counters
    init(_ counts: Counters) { self.counts = counts }
    public func destroy() throws { counts.add("disk") }
}
@MainActor public final class MACAddressPool {
    public static let shared = MACAddressPool()
    public var counters: [String: Counters] = [:]
    public func release(_ mac: String) { counters[mac]!.add("mac") }
}
@MainActor public final class VMPool {
'''
WARM = r'''
    public struct WarmVM {
        public let retirement = RetirementState()
        public let vm: FakeVM
        public let ephemeralDisk: FakeDisk
        public let serialInput: FakePipe
        public let serialOutput: FakePipe
        public let networkFilter: FakeStopper?
        public let graphicsSessions: [FakeStopper]
        public let macAddress: String?
        public let counters: Counters
        @MainActor public init(_ state: FakeVM.State) {
            vm = FakeVM(state)
            counters = Counters(vm)
            ephemeralDisk = FakeDisk(counters)
            serialInput = FakePipe("input", counters)
            serialOutput = FakePipe("output", counters)
            networkFilter = FakeStopper("network", counters)
            graphicsSessions = [FakeStopper("graphics", counters)]
            macAddress = UUID().uuidString
            MACAddressPool.shared.counters[macAddress!] = counters
        }
    }
'''
TESTS = r'''
}
struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
@MainActor struct Tests {
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message) }
    }
    static func pause(_ milliseconds: Int = 120) async throws {
        try await Task.sleep(for: .milliseconds(milliseconds))
    }
    static func eventually(_ predicate: () -> Bool, _ message: String) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !predicate() {
            try require(ProcessInfo.processInfo.systemUptime < deadline, message)
            try await pause(10)
        }
    }
    static func exactlyOnce(_ warm: VMPool.WarmVM) throws {
        let expected = ["mac": 1, "network": 1, "graphics": 1, "disk": 1,
                        "inputRead": 1, "inputWrite": 1, "outputRead": 1, "outputWrite": 1]
        try require(warm.counters.counts == expected, "cleanup counts: \(warm.counters.counts)")
        try require(warm.retirement.completed && warm.retirement.task == nil, "completed owner must release task")
    }
    static func concurrentCopiesAndRepeatedCall() async throws {
        let warm = VMPool.WarmVM(.running)
        let copy = warm
        try require(copy.retirement === warm.retirement, "WarmVM copies need same reference token")
        let calls = (0..<32).map { _ in Task { @MainActor in await VMPool.releaseResources(copy) } }
        for task in calls { try require(await task.value, "concurrent retirement failed") }
        try exactlyOnce(warm)
        try require(warm.vm.stopCount == 1, "duplicate stop request")
        try require(await VMPool.releaseResources(warm), "repeated completion failed")
        try exactlyOnce(warm)
        print("RETIREMENT_CONCURRENT_COPIES_PASS")
    }
    static func transitions() async throws {
        for state in [FakeVM.State.starting, .pausing, .resuming, .saving, .restoring] {
            let warm = VMPool.WarmVM(state)
            let call = Task { @MainActor in await VMPool.releaseResources(warm) }
            try await pause()
            try require(warm.vm.stopCount == 0 && warm.counters.counts.isEmpty, "transition released or stopped")
            warm.vm.state = .paused
            try require(await call.value, "transition never reaped")
            try require(warm.vm.stopCount == 1, "transition duplicate stop")
            try exactlyOnce(warm)
        }
        for terminal in [FakeVM.State.stopped, .error] {
            let warm = VMPool.WarmVM(terminal)
            try require(await VMPool.releaseResources(warm), "terminal cleanup failed")
            try require(warm.vm.stopCount == 0, "terminal VM was stopped again")
            try exactlyOnce(warm)
        }
        print("RETIREMENT_TRANSITIONS_PASS")
    }
    static func missingCallbackAndLateCallback() async throws {
        let warm = VMPool.WarmVM(.running)
        warm.vm.completeStopImmediately = false
        let call = Task { @MainActor in await VMPool.releaseResources(warm) }
        try await eventually({ warm.vm.stopCount == 1 }, "stop request missing")
        try require(warm.counters.counts.isEmpty, "stopping resources released")
        warm.vm.state = .stopped // framework state changes before/no callback
        try require(await call.value, "terminal state waited for callback")
        try exactlyOnce(warm)
        warm.vm.pendingCallback?(nil) // arbitrarily late callback must not clean again
        warm.vm.pendingCallback = nil
        try await pause()
        try exactlyOnce(warm)
        print("RETIREMENT_MISSING_LATE_CALLBACK_PASS")
    }
    static func cancelledWaiterLeavesOwner() async throws {
        let warm = VMPool.WarmVM(.running)
        warm.vm.completeStopImmediately = false
        let cancelled = Task { @MainActor in await VMPool.releaseResources(warm) }
        let survivor = Task { @MainActor in await VMPool.releaseResources(warm) }
        try await eventually({ warm.vm.stopCount == 1 }, "stop request missing")
        let start = ProcessInfo.processInfo.systemUptime
        cancelled.cancel()
        let result = await cancelled.value
        try require(!result, "cancelled wait cannot report completed cleanup")
        try require(ProcessInfo.processInfo.systemUptime - start < 1, "cancelled wait spun or blocked MainActor")
        try require(warm.counters.counts.isEmpty && warm.retirement.task != nil, "cancelled waiter discarded owner")
        warm.vm.state = .stopped
        try require(await survivor.value, "other waiter/reaper lost progress")
        try exactlyOnce(warm)
        print("RETIREMENT_CANCELLED_WAITER_PASS")
    }
    static func timeoutAndLateReaping() async throws {
        let warm = VMPool.WarmVM(.running)
        warm.vm.completeStopImmediately = false
        let start = ProcessInfo.processInfo.systemUptime
        let result = await VMPool.releaseResources(warm)
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        try require(!result && elapsed >= 29.5 && elapsed < 33, "30s timeout includes missing callback: \(elapsed)")
        try require(warm.vm.stopCount == 1 && warm.counters.counts.isEmpty, "timeout released resources or repeated stop")
        try require(warm.retirement.task != nil, "timeout lost owner")
        warm.vm.state = .error
        try await eventually({ warm.retirement.completed }, "late terminal state never reaped")
        try exactlyOnce(warm)
        warm.vm.pendingCallback?(nil)
        try require(await VMPool.releaseResources(warm), "late completion not reusable")
        try exactlyOnce(warm)
        print("RETIREMENT_TIMEOUT_LATE_REAP_PASS elapsed=\(elapsed)")
    }
    static func stopErrorRetainsUntilTerminal() async throws {
        let warm = VMPool.WarmVM(.running)
        warm.vm.stopError = true
        let task = Task { @MainActor in await VMPool.releaseResources(warm) }
        try await pause()
        try require(warm.vm.stopCount == 1 && warm.counters.counts.isEmpty, "failed stop released/retried")
        warm.vm.state = .error
        try require(await task.value, "error terminal state not reaped")
        try exactlyOnce(warm)
        print("RETIREMENT_STOP_ERROR_PASS")
    }
    static func run() async throws {
        try await concurrentCopiesAndRepeatedCall()
        try await transitions()
        try await missingCallbackAndLateCallback()
        try await cancelledWaiterLeavesOwner()
        try await stopErrorRetainsUntilTerminal()
        try await timeoutAndLateReaping()
        print("BROMURE_VM_RETIREMENT_ACTUAL_ROUTINE_PASS")
    }
}
@main struct Harness {
    @MainActor static func main() async {
        do { try await Tests.run() }
        catch { print("RETIREMENT_FAIL: \(error)"); exit(1) }
    }
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=Path(__file__).resolve().parents[2]/'Sources/SandboxEngine/VMPool.swift')
    parser.add_argument('--swiftc', default='swiftc')
    parser.add_argument('--emit', type=Path)
    parser.add_argument('--output-json', type=Path)
    args = parser.parse_args()
    original = args.source.read_text()
    start = original.index('    public final class RetirementState {')
    state = original[start:original.index('    public struct WarmVM {', start)]
    start = original.index('    public static func releaseResources(')
    routine = original[start:original.index('    /// Shut down the pool and clean up.', start)]
    if 'public let retirement = RetirementState()' not in original:
        raise RuntimeError('WarmVM retirement ownership changed; review fixture adaptation')
    generated = PRELUDE + state + WARM + routine + TESTS
    provenance = dict(source=str(args.source), sourceSHA256=hashlib.sha256(original.encode()).hexdigest(),
                      routineSHA256=hashlib.sha256(routine.encode()).hexdigest(),
                      generatedSHA256=hashlib.sha256(generated.encode()).hexdigest(),
                      scope='Actual source routine and owner token; fake VM/resources, real Swift Tasks and30s deadline')
    if args.emit:
        args.emit.write_text(generated)
        print(json.dumps(dict(provenance, emitted=str(args.emit))))
        return
    compiler = shutil.which(args.swiftc)
    if not compiler:
        raise RuntimeError('Swift compiler unavailable; --emit only generates source, never claims a pass')
    with tempfile.TemporaryDirectory(prefix='bromure-retirement-') as directory:
        path = Path(directory)
        (path/'fixture.swift').write_text(generated)
        subprocess.run([compiler, '-swift-version', '6', '-parse-as-library', str(path/'fixture.swift'), '-o', str(path/'fixture')], check=True, timeout=90)
        run = subprocess.run([str(path/'fixture')], capture_output=True, text=True, timeout=75)
        print(run.stdout, end='')
        print(run.stderr, end='')
        run.check_returncode()
        if 'BROMURE_VM_RETIREMENT_ACTUAL_ROUTINE_PASS' not in run.stdout:
            raise RuntimeError('fixture completion marker missing')
        provenance.update(passed=True, stdout=run.stdout, stderr=run.stderr)
        if args.output_json:
            args.output_json.write_text(json.dumps(provenance, indent=2)+'\n')
        print(json.dumps(provenance))


if __name__ == '__main__':
    main()
