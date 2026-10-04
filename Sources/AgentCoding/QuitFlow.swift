import Foundation

/// The quit flow's decisions, kept free of AppKit so they can be tested.
///
/// QH-2. AppKit won't terminate while a window has a sheet attached. A quit
/// Apple Event (Dock, `osascript`, log-out) and `NSApp.terminate` (the Quit
/// menu, ⌘Q, the status item, the guest-bounced ⌘Q after its drain) both
/// return right away. The unified log says "App termination blocked by modal
/// sheet", the delegate's `applicationShouldTerminate` is never called, and
/// the Apple Event fails with -128. Nothing in the app sees it happen. A
/// fat-client mirror window puts sheets up on its own: the "Turn on the VPN?"
/// offer the first time an agent opens its browser, and the server's
/// decision prompts. One of those, possibly behind another window, made quit
/// do nothing again and again.
///
/// The app therefore takes the quit Apple Event and the Quit menu items
/// itself and decides here first. Every request gets one of three outcomes:
/// it shows the confirmation and acts on the answer, it terminates, or it
/// waits for a quit that is already in progress. A request is never dropped
/// without a log line.
enum QuitFlow {
    /// Where the quit flow stands.
    enum Phase: Equatable {
        /// No quit in progress.
        case idle
        /// The "N VMs running — quit?" confirmation is on screen (its
        /// `runModal` still services Apple Events, so a second Quit can
        /// arrive while it is up).
        case confirming
        /// Confirmed; the VMs are draining. Either `.terminateLater` is
        /// pending, or the guest-bounced path is draining before it
        /// terminates.
        case draining
    }

    /// What to do with a quit request.
    enum Request: Equatable {
        /// The confirmation is already up. Bring it forward; don't stack a
        /// second one.
        case refrontConfirmation
        /// A drain is in flight and already owes its terminate. Log the
        /// request and wait; never cancel the pending quit.
        case awaitDrain
        /// Nothing is in the way. `NSApp.terminate`, and
        /// `applicationShouldTerminate` confirms as it always has.
        case terminate
        /// Sheets are attached, so AppKit would refuse silently. Confirm
        /// first. On Quit, dismiss the sheets and terminate pre-confirmed. On
        /// Cancel, the sheets stay as they were.
        case confirmThenDismissSheets
    }

    static func request(phase: Phase, attachedSheets: Int) -> Request {
        switch phase {
        case .confirming: return .refrontConfirmation
        case .draining: return .awaitDrain
        case .idle: return attachedSheets > 0 ? .confirmThenDismissSheets : .terminate
        }
    }

    /// `applicationShouldTerminate`'s verdict.
    enum Reply: Equatable {
        case cancel
        case now
        case later
    }

    /// - Parameters:
    ///   - phase: the phase when AppKit asked. `.draining` means a terminate
    ///     is already owed, and `.confirming` means the confirmation is
    ///     still on screen. AppKit doesn't normally ask twice, but if it
    ///     does, the second request must not start a second drain or stack
    ///     a second alert.
    ///   - confirmed: the user's answer, or true when nothing needed asking.
    ///   - workRunning: any workspace VM or browser VM still up.
    static func shouldTerminate(phase: Phase, confirmed: Bool, workRunning: Bool) -> Reply {
        // Already owed (draining), or the confirmation is still up and will
        // decide: never start a second quit inside the first.
        if phase != .idle { return .cancel }
        guard confirmed else { return .cancel }
        return workRunning ? .later : .now
    }
}
