import Foundation

/// Serializes one shared browser VM's window operations (the guest
/// controller takes one request at a time).
///
/// User-driven work wakes an idle-suspended VM first. Background polling
/// never does: while the VM is suspended a background operation is skipped,
/// so a periodic poll can't keep resuming a VM the energy setting paused
/// (each resume restarts its idle countdown). At most one background
/// operation is pending or running at a time.
@MainActor
public final class SharedWindowOperationQueue {
    public typealias Operation = () async -> Void

    /// Resumes the VM if it is idle-suspended (before user-driven work).
    public var resumeVM: () -> Void = {}
    /// Whether the VM is idle-suspended.
    public var isVMSuspended: () -> Bool = { false }

    private var operations: [(motion: Int?, background: Bool, body: Operation)] = []
    private var draining = false
    private var backgroundOutstanding = false

    public init() {}

    /// Queues `operation`. A pointer-motion operation for the same window
    /// replaces a still-queued one (`coalescingMotion`). A `background`
    /// operation is dropped when one is already outstanding.
    public func enqueue(coalescingMotion id: Int? = nil, background: Bool = false,
                        _ operation: @escaping Operation) {
        if background {
            guard !backgroundOutstanding else { return }
            backgroundOutstanding = true
        }
        if let id, !background, let last = operations.last, last.motion == id, !last.background {
            operations[operations.count - 1] = (id, false, operation)
        } else {
            operations.append((background ? nil : id, background, operation))
        }
        guard !draining else { return }
        draining = true
        Task { @MainActor in
            while !operations.isEmpty {
                let next = operations.removeFirst()
                if next.background {
                    defer { backgroundOutstanding = false }
                    if isVMSuspended() { continue }
                    await next.body()
                } else {
                    resumeVM()
                    await next.body()
                }
            }
            draining = false
        }
    }
}
