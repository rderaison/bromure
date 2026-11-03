import AppKit

/// The app's NSApplication: what AppKit does with an Objective-C exception
/// it catches on the main thread.
///
/// `-[NSApplication run]` catches an exception thrown while it runs the
/// event loop — main-queue blocks, timers, and with them every main-actor
/// Swift job — logs it, and carries on. When the exception unwound through
/// a Swift job (`swift_job_run`), the concurrency runtime's per-thread
/// record of the running executor was never put back (its frame has no
/// exception cleanup): it points into a dead stack frame, and the next
/// "am I on the main actor?" check — any `MainActor.assumeIsolated` —
/// reads garbage and crashes there, far from the cause, with nothing in the
/// report to say what happened (5.2.3: EXC_BAD_ACCESS in
/// `swift_task_isMainExecutorImpl`, from the sessions' 2 s reconcile timer,
/// after 28 h of uptime).
///
/// So every caught exception is written to the app log with its stack, and
/// one that crossed a Swift job stops the app right there, the exception
/// named in the crash report, instead of running on in a corrupted state —
/// but only when this Mac runs no VMs of its own (a fat client mirroring a
/// remote): stopping a native instance would take its workspaces down with
/// it, so there the app carries on and may still crash later. An exception
/// that didn't cross a Swift job (plain event handling) is survived, as before.
final class BromureApplication: NSApplication {
    override func reportException(_ exception: NSException) {
        let stack = exception.callStackSymbols
        FileHandle.standardError.write(Data((
            "[exception] \(exception.name.rawValue): \(exception.reason ?? "")\n"
            + stack.map { "  \($0)" }.joined(separator: "\n") + "\n").utf8))
        let crossed = Self.crossedSwiftJob(stack)
        let hostsVMs = crossed && UbuntuSandboxVM.anyLive
        if Self.stopsApp(crossedSwiftJob: crossed, hostsVMs: hostsVMs) {
            fatalError("Objective-C exception inside a Swift task — \(exception.name.rawValue): \(exception.reason ?? "")")
        }
        if crossed {
            FileHandle.standardError.write(Data(
                "[exception] it crossed a Swift task, but local VMs are running — carrying on; the app may crash later\n".utf8))
        }
        super.reportException(exception)
    }

    /// Stop here only when nothing local would go down with the app.
    nonisolated static func stopsApp(crossedSwiftJob: Bool, hostsVMs: Bool) -> Bool {
        crossedSwiftJob && !hostsVMs
    }

    /// The exception was thrown under a Swift concurrency job: its stack
    /// (an async task's frames, as the exception records them) reaches into
    /// the concurrency runtime (`completeTaskWithClosure`, `swift_job_run`…).
    nonisolated static func crossedSwiftJob(_ callStack: [String]) -> Bool {
        callStack.contains { $0.contains("libswift_Concurrency") || $0.contains("swift_job_run") }
    }
}
