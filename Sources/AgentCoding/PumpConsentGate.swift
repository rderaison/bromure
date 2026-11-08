import Foundation

extension ACAutomationServer {
    // Active interactive (CLI/SSH) attaches → the gate the host uses to present a
    // consent prompt on the USER's side of the pump (never in the guest). SHARED
    // (static) across all AutomationServer instances (control-socket + TCP); one
    // gate per profile (the most recent attach wins).
    private static let attachLock = NSLock()
    nonisolated(unsafe) private static var consentGates: [String: PumpConsentGate] = [:]

    /// True while `profileID` has a live interactive (CLI/SSH) attach — i.e. a
    /// consent prompt can be shown on the user's terminal instead of an NSAlert.
    static func isInteractivelyAttached(_ profileID: String) -> Bool {
        attachLock.lock(); defer { attachLock.unlock() }
        return consentGates[profileID] != nil
    }

    /// Present a consent prompt on the attached user's terminal (host side of the
    /// pump) and return the chosen 0-based index — or nil (no live attach / the
    /// user dismissed / timed out), which every broker maps to deny.
    static func presentConsentViaPump(profileID: String, prompt: String,
                                      choices: [String], timeoutSeconds: TimeInterval,
                                      token: UUID = UUID()) -> Int? {
        attachLock.lock(); let gate = consentGates[profileID]; attachLock.unlock()
        return gate?.ask(id: token, prompt: prompt, choices: choices, timeout: timeoutSeconds)
    }

    /// Take back the terminal prompt asked with `token` (a Guardrails
    /// decision overtook it): its asker gets nil now, and the terminal stops
    /// showing it.
    static func withdrawConsentViaPump(token: UUID) {
        attachLock.lock(); let gates = Array(consentGates.values); attachLock.unlock()
        for g in gates { g.withdraw(token) }
    }

    static func registerGate(_ gate: PumpConsentGate, for profileID: String) {
        attachLock.lock(); consentGates[profileID] = gate; attachLock.unlock()
    }
    static func unregisterGate(_ gate: PumpConsentGate, for profileID: String) {
        attachLock.lock()
        if consentGates[profileID] === gate { consentGates[profileID] = nil }
        attachLock.unlock()
        // Detached while prompts were outstanding → wake the blocked brokers
        // now (deny) instead of letting them wait out the full timeout.
        gate.failAll()
    }

    /// Hand-off between brokers (any thread) and the pump that owns the user's
    /// terminal: each `ask` queues its prompt under its own id and blocks; the
    /// pump claims the oldest via `takePending`, renders it, and `deliver`s
    /// the chosen index to that id alone. One shared prompt/answer/semaphore
    /// let a second ask (another credential, or a fresh prompt after an
    /// overtaken one) overwrite the first, and a keystroke for one prompt
    /// complete another. Sendable: its asks are only touched under `lock`.
    final class PumpConsentGate: @unchecked Sendable {
        private final class Ask {
            let id: UUID
            let prompt: String
            let choices: [String]
            let timeout: TimeInterval
            let done = DispatchSemaphore(value: 0)
            var answer: Int?
            var taken = false
            var finished = false
            init(id: UUID, prompt: String, choices: [String], timeout: TimeInterval) {
                self.id = id; self.prompt = prompt; self.choices = choices; self.timeout = timeout
            }
        }
        private let lock = NSLock()
        private var asks: [Ask] = []   // oldest first

        func ask(id: UUID = UUID(), prompt: String, choices: [String], timeout: TimeInterval) -> Int? {
            let a = Ask(id: id, prompt: prompt, choices: choices, timeout: timeout)
            lock.lock(); asks.append(a); lock.unlock()
            // Wait a little past the in-terminal read so the pump delivers first.
            _ = a.done.wait(timeout: .now() + timeout + 10)
            lock.lock(); defer { lock.unlock() }
            asks.removeAll { $0 === a }
            return a.finished ? a.answer : nil
        }
        /// Pump side: claim the oldest prompt not yet shown (once).
        func takePending() -> (id: UUID, prompt: String, choices: [String], timeout: TimeInterval)? {
            lock.lock(); defer { lock.unlock() }
            guard let a = asks.first(where: { !$0.taken && !$0.finished }) else { return nil }
            a.taken = true
            return (a.id, a.prompt, a.choices, a.timeout)
        }
        /// Pump side: the chosen index (or nil) for prompt `id` — only that
        /// one; a prompt already withdrawn ignores it.
        func deliver(_ idx: Int?, to id: UUID) { finish(id, idx) }
        /// The asker no longer wants an answer: it gets nil now.
        func withdraw(_ id: UUID) { finish(id, nil) }
        /// Still waiting for its answer (the terminal keeps showing it).
        func isOpen(_ id: UUID) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return asks.contains { $0.id == id && !$0.finished }
        }
        /// The attach ended: every waiting asker gets nil.
        func failAll() {
            lock.lock(); let open = asks.filter { !$0.finished }; lock.unlock()
            for a in open { finish(a.id, nil) }
        }
        private func finish(_ id: UUID, _ idx: Int?) {
            lock.lock()
            guard let a = asks.first(where: { $0.id == id && !$0.finished }) else { lock.unlock(); return }
            a.finished = true
            a.answer = idx
            lock.unlock()
            a.done.signal()
        }
    }
}

extension ACAutomationServer {
    /// What the user's terminal shows for a consent prompt, and how their
    /// keystrokes answer it. The interactive attach is a framed pty protocol
    /// ([type:u8][len:u32-BE][payload]; type 0=data, 1=resize, 2=exit,
    /// 3=stdin-EOF), so the screen goes out as type-0 frames and the client's
    /// framed keystrokes are decoded — raw bytes wouldn't render.
    enum PumpConsentScreen {
        /// The prompt, cleared in place (no nested alt screen), as one frame.
        static func prompt(_ prompt: String, choices: [String]) -> [UInt8] {
            var s = "\u{1b}[2J\u{1b}[H"                                 // clear, home
            s += "\u{1b}[1;33m🔒 Bromure — approval required\u{1b}[0m\r\n\r\n"
            s += prompt.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n\r\n"
            for (i, c) in choices.enumerated() { s += "  \u{1b}[1m\(i + 1)\u{1b}[0m) \(c)\r\n" }
            s += "\r\nChoice [1-\(choices.count)]  (Enter or timeout = deny): "
            return frame(0, Array(s.utf8))
        }

        /// Clears the prompt away (the caller repaints tmux next), as one frame.
        static let clear = frame(0, Array("\u{1b}[2J\u{1b}[H".utf8))

        /// One pty-protocol frame: [type:u8][len:u32-BE][payload].
        static func frame(_ type: UInt8, _ payload: [UInt8]) -> [UInt8] {
            var out: [UInt8] = [type,
                UInt8((UInt32(payload.count) >> 24) & 0xff), UInt8((UInt32(payload.count) >> 16) & 0xff),
                UInt8((UInt32(payload.count) >> 8) & 0xff),  UInt8(UInt32(payload.count) & 0xff)]
            out.append(contentsOf: payload)
            return out
        }

        /// The client's framed keystrokes, as they arrive, until they answer:
        /// a digit in range is that choice; Enter or stdin EOF is a deny.
        struct Keys {
            enum Outcome: Equatable { case pending, answered(Int?) }
            let choices: Int
            private var inbuf: [UInt8] = []
            init(choices: Int) { self.choices = choices; inbuf.reserveCapacity(256) }

            mutating func feed(_ bytes: some Collection<UInt8>) -> Outcome {
                inbuf.append(contentsOf: bytes)
                while inbuf.count >= 5 {
                    let ftype = inbuf[0]
                    let flen = (Int(inbuf[1]) << 24) | (Int(inbuf[2]) << 16)
                             | (Int(inbuf[3]) << 8) | Int(inbuf[4])
                    if inbuf.count < 5 + flen { break }                 // partial frame; wait for more
                    let payload = Array(inbuf[5 ..< 5 + flen])
                    inbuf.removeFirst(5 + flen)
                    if ftype == 3 { return .answered(nil) }             // stdin EOF → deny
                    guard ftype == 0 else { continue }                  // ignore resize (1) etc.
                    for ch in payload {
                        if ch == 0x0d || ch == 0x0a { return .answered(nil) }  // Enter → deny
                        if ch >= 0x31, ch <= 0x39 {                     // '1'..'9'
                            let d = Int(ch - 0x30)
                            if d >= 1, d <= choices { return .answered(d - 1) }
                        }
                    }
                }
                return .pending
            }
        }
    }
}
