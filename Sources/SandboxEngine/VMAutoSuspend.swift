import AppKit
import Virtualization

/// User-selectable policy for VM idle-suspend.
public enum EnergyMode: String, CaseIterable, Sendable {
    /// Never suspend.
    case highPower
    /// Suspend after idle only when macOS is in Low Power Mode (default).
    case automatic
    /// Always suspend after idle regardless of macOS energy state.
    case lowPower

    public static let `default`: EnergyMode = .automatic

    public init(storageValue: String) {
        self = EnergyMode(rawValue: storageValue) ?? .default
    }
}

/// Automatically pauses a VM when the session is idle and resumes it on interaction.
///
/// Whether idle actually triggers a suspend depends on the active
/// ``EnergyMode`` (provided via ``modeProvider``):
///   - ``EnergyMode/highPower``: never suspend
///   - ``EnergyMode/automatic``: suspend only while macOS Low Power Mode is on
///   - ``EnergyMode/lowPower``: suspend whenever idle conditions hold
///
/// Idle is defined as ALL of the following being true for ``idleThreshold`` seconds:
///   - Energy-mode gate above permits suspension
///   - Window is not key (out of focus)
///   - No network traffic (packet count unchanged)
///   - No camera or microphone active
///
/// When the window becomes key again, or the effective gate flips to "don't
/// suspend," the VM is resumed immediately.
@MainActor
public final class VMAutoSuspend {
    /// How long all idle conditions must hold before suspending.
    public var idleThreshold: TimeInterval = 180

    /// How often to check idle conditions.
    private static let checkInterval: TimeInterval = 5

    /// Packet delta per ``checkInterval`` that counts as "active" traffic.
    /// Background chatter (DNS keep-alives, TCP keep-alives, service-worker
    /// pings, DHCP renewals) and ad-heavy pages with autoplay trackers can
    /// emit dozens of packets a second without the user doing anything.
    /// Require sustained traffic (~40 packets/sec) so an ad-laden but
    /// unattended tab still suspends; streaming media stays well above this.
    private static let activityPacketThreshold: UInt64 = 200

    /// Throttle for the per-tick diagnostic log.
    private static let diagLogInterval: TimeInterval = 30

    private weak var vm: VZVirtualMachine?
    private weak var window: NSWindow?
    private var networkFilter: NetworkFilter?

    /// External check: is the webcam actively streaming?
    private var isWebcamStreaming = false
    /// External check: is the microphone enabled for this session?
    private let isMicrophoneEnabled: Bool
    /// Reads the current energy mode on demand — called every tick so live
    /// changes from Settings take effect without tearing down the session.
    private let modeProvider: @MainActor () -> EnergyMode
    /// Last energy mode we observed, used to detect gate transitions.
    private var lastMode: EnergyMode
    /// Last LPM reading, used to detect transitions while in .automatic.
    private var lastLPM: Bool

    private var isSuspended = false
    private var lastPacketCount: UInt64 = 0
    private var idleStart: Date?
    private var checkTimer: Timer?
    private var lastDiagLog: Date?
    private var focusObservers: [NSObjectProtocol] = []
    private var powerObserver: NSObjectProtocol?

    /// Called when the VM is suspended or resumed. Bool = isSuspended.
    public var onStateChanged: ((Bool) -> Void)?

    public init(
        vm: VZVirtualMachine,
        window: NSWindow,
        networkFilter: NetworkFilter?,
        isMicrophoneEnabled: Bool,
        modeProvider: @escaping @MainActor () -> EnergyMode
    ) {
        self.vm = vm
        self.window = window
        self.networkFilter = networkFilter
        self.isMicrophoneEnabled = isMicrophoneEnabled
        self.modeProvider = modeProvider
        self.lastMode = modeProvider()
        self.lastLPM = ProcessInfo.processInfo.isLowPowerModeEnabled

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

        print("[VMAutoSuspend] armed — idle threshold: \(Int(self.idleThreshold))s, mode: \(lastMode.rawValue), low-power-mode: \(lastLPM)")
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

    /// Whether the current mode + system state permits suspending on idle.
    private func suspensionAllowed(mode: EnergyMode, lpm: Bool) -> Bool {
        switch mode {
        case .highPower: return false
        case .automatic: return lpm
        case .lowPower: return true
        }
    }

    private func handlePowerStateChanged() {
        let lpm = ProcessInfo.processInfo.isLowPowerModeEnabled
        lastLPM = lpm
        print("[VMAutoSuspend] low-power-mode changed: \(lpm)")
        reevaluateGate()
    }

    /// Called when the effective gate (mode or LPM) may have changed.
    /// Resumes the VM if we're now in a "don't suspend" regime, and resets
    /// the idle accumulator so we start timing from the new state.
    private func reevaluateGate() {
        let mode = modeProvider()
        let allowed = suspensionAllowed(mode: mode, lpm: lastLPM)
        if !allowed {
            // Gate closed — resume right away so the user isn't surprised
            // by a frozen tab the first time they glance at it.
            if isSuspended {
                resumeVM()
            }
            idleStart = nil
        } else {
            // Gate opened — start accumulating idle time from now if the
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

        // Pick up live changes to energy mode or LPM between ticks.
        let mode = modeProvider()
        let lpm = ProcessInfo.processInfo.isLowPowerModeEnabled
        if mode != lastMode || lpm != lastLPM {
            if mode != lastMode {
                print("[VMAutoSuspend] energy mode changed: \(lastMode.rawValue) → \(mode.rawValue)")
            }
            lastMode = mode
            lastLPM = lpm
            reevaluateGate()
        }

        // Sample every gate each tick so the diagnostic log can explain
        // exactly what's preventing suspension.
        let currentPacketCount = networkFilter?.packetCount ?? 0
        let packetsThisTick = currentPacketCount &- lastPacketCount
        lastPacketCount = currentPacketCount
        let allowed = suspensionAllowed(mode: mode, lpm: lpm)
        let isKey = window.isKeyWindow
        let mediaActive = isWebcamStreaming || isMicrophoneEnabled
        let trafficActive = packetsThisTick > Self.activityPacketThreshold

        var blocker: String?
        if isSuspended { blocker = "already suspended" }
        else if !allowed { blocker = "mode=\(mode.rawValue) lpm=\(lpm)" }
        else if isKey { blocker = "window is key" }
        else if mediaActive { blocker = "media active" }
        else if trafficActive { blocker = "traffic \(packetsThisTick) pkts/tick" }

        if let blocker {
            idleStart = nil
            logDiag("blocked: \(blocker)", idleDuration: 0)
            return
        }

        // All conditions met — accumulate idle time.
        if idleStart == nil {
            idleStart = Date()
        }
        let idleDuration = Date().timeIntervalSince(idleStart!)
        logDiag("idle \(packetsThisTick) pkts/tick", idleDuration: idleDuration)
        if idleDuration >= idleThreshold {
            suspendVM()
        }
    }

    /// Throttled diagnostic log so a user can see why suspend isn't firing
    /// without producing a line every 5 seconds.
    private func logDiag(_ reason: String, idleDuration: TimeInterval) {
        let now = Date()
        if let last = lastDiagLog, now.timeIntervalSince(last) < Self.diagLogInterval {
            return
        }
        lastDiagLog = now
        print("[VMAutoSuspend] \(reason), idle \(Int(idleDuration))s / \(Int(idleThreshold))s")
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
