import Foundation
import NIOConcurrencyHelpers
import NIOCore

/// An interactive exec's pump (macOS: ACAutomationServer.pump over the
/// CLI's fd and the guest's vsock): bytes both ways unchanged until either
/// side ends. With a consent gate, a prompt the gate hands over shows on the
/// user's terminal (the host's side of the pump; the guest never sees it):
/// the guest's output waits meanwhile, and the user's keystrokes answer the
/// prompt instead of reaching the guest, so a compromised guest can neither
/// see the prompt nor forge its answer (macOS: presentConsent, which the
/// pump runs in place of its own reads).
enum ConsentPump {
    typealias Screen = ACAutomationServer.PumpConsentScreen

    /// What the pump's sides share about the prompt on screen.
    final class Showing: @unchecked Sendable {
        private struct State {
            var keys: Screen.Keys?            // a prompt shows
            var answer: Screen.Keys.Outcome = .pending
            var guestWriting = false
        }
        private let state = NIOLockedValueBox(State())

        /// The user's bytes go to the prompt on screen, if one is (true: they
        /// are taken, not forwarded).
        // @port-skip linux-only: the pump's prompt state across its async sides (macOS: one poll loop)
        func take(_ b: ByteBuffer) -> Bool {
            state.withLockedValue { s in
                guard s.keys != nil else { return false }
                if s.answer == .pending { s.answer = s.keys!.feed(b.readableBytesView) }
                return true
            }
        }
        /// The guest may write to the user now (false while a prompt shows).
        // @port-skip linux-only: the pump's prompt state across its async sides (macOS: one poll loop)
        func beginGuestWrite() -> Bool {
            state.withLockedValue { s in
                guard s.keys == nil else { return false }
                s.guestWriting = true
                return true
            }
        }
        // @port-skip linux-only: the pump's prompt state across its async sides (macOS: one poll loop)
        func endGuestWrite() { state.withLockedValue { $0.guestWriting = false } }
        /// A prompt shows from now: the guest's next write waits, the user's
        /// bytes answer it.
        // @port-skip linux-only: the pump's prompt state across its async sides (macOS: one poll loop)
        func show(choices: Int) {
            state.withLockedValue { $0.keys = Screen.Keys(choices: choices); $0.answer = .pending }
        }
        // @port-skip linux-only: the pump's prompt state across its async sides (macOS: one poll loop)
        var guestWriting: Bool { state.withLockedValue { $0.guestWriting } }
        // @port-skip linux-only: the pump's prompt state across its async sides (macOS: one poll loop)
        var answer: Screen.Keys.Outcome { state.withLockedValue { $0.answer } }
        // @port-skip linux-only: the pump's prompt state across its async sides (macOS: one poll loop)
        func hide() { state.withLockedValue { $0.keys = nil } }
    }

    /// Pumps until either side ends. `gate` nil: a plain pump (a GUI-fronted
    /// attach, whose consent goes to the fat client). `afterConsent`: after
    /// each prompt (the guest's tmux repainted over it).
    // @port ACAutomationServer.static pump(_: Int32, _: Int32, gate: PumpConsentGate?, afterConsent: (()->Void)?) h=65a9646c1f16fe74 @61818379
    static func run<C: AsyncSequence & Sendable, G: AsyncSequence & Sendable>(
        client: C, toClient: @escaping @Sendable (ByteBuffer) async throws -> Void,
        guest: G, toGuest: @escaping @Sendable (ByteBuffer) async throws -> Void,
        gate: ACAutomationServer.PumpConsentGate?,
        poll: Duration = .milliseconds(200),
        afterConsent: @escaping @Sendable () async -> Void = {}
    ) async where C.Element == ByteBuffer, G.Element == ByteBuffer {
        let showing = Showing()
        await withTaskGroup(of: Void.self) { g in
            g.addTask {
                do {
                    for try await b in client {
                        if gate != nil, showing.take(b) { continue }
                        try await toGuest(b)
                    }
                } catch {}
            }
            g.addTask {
                do {
                    for try await b in guest {
                        while gate != nil, !showing.beginGuestWrite() { try await Task.sleep(for: .milliseconds(20)) }
                        defer { showing.endGuestWrite() }
                        try await toClient(b)
                    }
                } catch {}
            }
            if let gate {
                g.addTask {
                    while !Task.isCancelled {
                        guard let p = gate.takePending() else {
                            do { try await Task.sleep(for: poll) } catch { return }
                            continue
                        }
                        let choice = await present(p, gate: gate, showing: showing, toClient: toClient)
                        gate.deliver(choice, to: p.id)
                        await afterConsent()
                    }
                }
            }
            // Either side's end ends the pump (the prompt loop never ends first).
            await g.next()
            g.cancelAll()
        }
    }

    /// One prompt on the user's terminal: shown once the guest's write under
    /// way is done, answered by a digit in range; Enter, stdin EOF, the
    /// timeout, a withdrawal or the attach ending deny (nil).
    // @port ACAutomationServer.static presentConsent(clientFD: Int32, prompt: String, choices: [String], timeout: TimeInterval, stillAsked: ()->Bool) h=1fe1fdb20e91c223 @61818379
    private static func present(_ p: (id: UUID, prompt: String, choices: [String], timeout: TimeInterval),
                                gate: ACAutomationServer.PumpConsentGate, showing: Showing,
                                toClient: @Sendable (ByteBuffer) async throws -> Void) async -> Int? {
        showing.show(choices: p.choices.count)
        defer { showing.hide() }
        while showing.guestWriting {
            do { try await Task.sleep(for: .milliseconds(5)) } catch { return nil }
        }
        do { try await toClient(ByteBuffer(bytes: Screen.prompt(p.prompt, choices: p.choices))) } catch { return nil }
        let deadline = Date().addingTimeInterval(p.timeout)
        var choice: Int?
        while true {
            if case .answered(let c) = showing.answer { choice = c; break }
            if Date() >= deadline || !gate.isOpen(p.id) { break }   // timed out, or withdrawn
            do { try await Task.sleep(for: .milliseconds(25)) } catch { break }
        }
        try? await toClient(ByteBuffer(bytes: Screen.clear))
        return choice
    }
}
