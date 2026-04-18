import AppKit
import Virtualization

/// Automatically pauses a VM when the session is idle and resumes it on interaction.
///
/// Suspending is gated on macOS Low Power Mode — when LPM is off, the auto
/// suspend is inert and the VM stays running even when idle. This matches
/// user intent: they've opted into power savings system-wide.
///
/// Idle is defined as ALL of the following being true for ``idleThreshold`` seconds:
///   - Low Power Mode is enabled
///   - Window is not key (out of focus)
///   - No network traffic (packet count unchanged)
///   - No camera or microphone active
///
/// When the window becomes key again or LPM turns off, the VM is resumed
/// immediately.
@MainActor
public final class VMAutoSuspend {
    /// How long all idle conditions must hold before suspending.
    public var idleThreshold: TimeInterval = 180

    /// How often to check idle conditions.
    private static let checkInterval: TimeInterval = 5

    private weak var vm: VZVirtualMachine?
    private weak var window: NSWindow?
    private var networkFilter: NetworkFilter?

    /// External check: is the webcam actively streaming?
    private var isWebcamStreaming = false
    /// External check: is the microphone enabled for this session?
    private let isMicrophoneEnabled: Bool

    private var isSuspended = false
    private var lastPacketCount: UInt64 = 0
    private var idleStart: Date?
    private var checkTimer: Timer?
    private var focusObservers: [NSObjectProtocol] = []
    private var powerObserver: NSObjectProtocol?

    /// Called when the VM is suspended or resumed. Bool = isSuspended.
    public var onStateChanged: ((Bool) -> Void)?

    public init(
        vm: VZVirtualMachine,
        window: NSWindow,
        networkFilter: NetworkFilter?,
        isMicrophoneEnabled: Bool
    ) {
        self.vm = vm
        self.window = window
        self.networkFilter = networkFilter
        self.isMicrophoneEnabled = isMicrophoneEnabled

        if let nf = networkFilter {
            lastPacketCount = nf.packetCount
        }

        // Observe window focus changes
        let nc = NotificationCenter.default
        focusObservers.append(
            nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleWindowFocused() }
            }
        )
        focusObservers.append(
            nc.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleWindowUnfocused() }
            }
        )

        // Start periodic idle check
        checkTimer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkIdle()
            }
        }

        // Observe Low Power Mode changes: resume immediately on transition off,
        // reset idle tracking on transition on.
        powerObserver = nc.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handlePowerStateChanged() }
        }

        let lpm = ProcessInfo.processInfo.isLowPowerModeEnabled
        print("[VMAutoSuspend] armed — idle threshold: \(Int(self.idleThreshold))s, low-power-mode: \(lpm)")
    }

    nonisolated deinit {
        // Timer and observers are cleaned up via stop() called from BrowserSession.teardown()
    }

    public func stop() {
        checkTimer?.invalidate()
        checkTimer = nil
        for obs in focusObservers {
            NotificationCenter.default.removeObserver(obs)
        }
        focusObservers.removeAll()
        if let powerObserver {
            NotificationCenter.default.removeObserver(powerObserver)
            self.powerObserver = nil
        }

        // Resume if we're being torn down while suspended
        if isSuspended {
            resumeVM()
        }
    }

    /// Resume the VM if it is currently suspended (e.g. for an incoming API request).
    public func resumeForAPIRequest() {
        if isSuspended {
            resumeVM()
        }
    }

    /// Call this from WebcamBridge.onStreamingChanged to update webcam state.
    public func setWebcamStreaming(_ streaming: Bool) {
        isWebcamStreaming = streaming
        // If webcam just started, resume immediately
        if streaming && isSuspended {
            resumeVM()
        }
    }

    // MARK: - Power handling

    private func handlePowerStateChanged() {
        let lpm = ProcessInfo.processInfo.isLowPowerModeEnabled
        print("[VMAutoSuspend] low-power-mode changed: \(lpm)")
        if !lpm {
            // Coming out of LPM: resume right away so the user isn't surprised
            // by a frozen tab the first time they glance at it.
            if isSuspended {
                resumeVM()
            }
            idleStart = nil
        } else {
            // Entering LPM: start accumulating idle time from now if the
            // window is already backgrounded.
            if let window, !window.isKeyWindow {
                idleStart = Date()
                lastPacketCount = networkFilter?.packetCount ?? 0
            }
        }
    }

    // MARK: - Focus handling

    private func handleWindowFocused() {
        idleStart = nil
        if isSuspended {
            resumeVM()
        }
    }

    private func handleWindowUnfocused() {
        // Start tracking idle time from now
        if idleStart == nil {
            idleStart = Date()
            lastPacketCount = networkFilter?.packetCount ?? 0
        }
    }

    // MARK: - Idle checking

    private func checkIdle() {
        guard vm != nil, let window else { return }
        guard !isSuspended else { return }

        // Condition 0: macOS is in Low Power Mode. Outside of LPM the VM keeps
        // running even when idle — users on AC power don't want "why is my tab
        // frozen" surprises. LPM is an explicit opt-in for aggressive savings.
        guard ProcessInfo.processInfo.isLowPowerModeEnabled else {
            idleStart = nil
            return
        }

        // Condition 1: window must not be key
        guard !window.isKeyWindow else {
            idleStart = nil
            return
        }

        // Condition 2: no camera or microphone active
        if isWebcamStreaming || isMicrophoneEnabled {
            idleStart = nil
            return
        }

        // Condition 3: no network traffic
        let currentPacketCount = networkFilter?.packetCount ?? 0
        if currentPacketCount != lastPacketCount {
            // Traffic detected — reset idle timer
            lastPacketCount = currentPacketCount
            idleStart = Date()
            return
        }

        // All conditions met — check duration
        guard let start = idleStart else {
            idleStart = Date()
            lastPacketCount = currentPacketCount
            return
        }

        let idleDuration = Date().timeIntervalSince(start)
        if idleDuration >= idleThreshold {
            suspendVM()
        }
    }

    // MARK: - VM suspend/resume

    private func suspendVM() {
        guard let vm, !isSuspended, vm.canPause else { return }
        isSuspended = true
        print("[VMAutoSuspend] suspending VM (idle for \(Int(idleThreshold))s)")
        Task { @MainActor in
            do {
                try await vm.pause()
                self.onStateChanged?(true)
            } catch {
                print("[VMAutoSuspend] pause failed: \(error)")
                self.isSuspended = false
            }
        }
    }

    private func resumeVM() {
        guard let vm, isSuspended else { return }
        isSuspended = false
        idleStart = nil
        lastPacketCount = networkFilter?.packetCount ?? 0
        print("[VMAutoSuspend] resuming VM")
        Task { @MainActor in
            do {
                try await vm.resume()
                self.onStateChanged?(false)
            } catch {
                print("[VMAutoSuspend] resume failed: \(error)")
            }
        }
    }
}
