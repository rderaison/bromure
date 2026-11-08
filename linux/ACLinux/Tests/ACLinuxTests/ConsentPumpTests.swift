import Foundation
import NIOConcurrencyHelpers
import NIOCore
import Testing
@testable import ACLinux

/// The interactive exec's pump with a terminal consent gate (macOS:
/// ACAutomationServer.pump with presentConsent): a prompt asked through the
/// gate shows on the user's side only, their digit answers it and never
/// reaches the guest, the guest's output waits while it shows, and the
/// bytes flow as before once it's gone.
@Suite("Terminal consent pump")
struct ConsentPumpTests {
    typealias Screen = ACAutomationServer.PumpConsentScreen

    final class Side: @unchecked Sendable {
        let (stream, input) = AsyncStream<ByteBuffer>.makeStream()
        let written = NIOLockedValueBox<[UInt8]>([])
        func send(_ b: [UInt8]) { input.yield(ByteBuffer(bytes: b)) }
        var bytes: [UInt8] { written.withLockedValue { $0 } }
        func write(_ b: ByteBuffer) { written.withLockedValue { $0 += b.readableBytesView } }
    }

    static func until(_ what: @autoclosure () -> Bool) async throws {
        for _ in 0..<500 {
            if what() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    static func ask(_ gate: ACAutomationServer.PumpConsentGate, timeout: TimeInterval = 30) -> NIOLockedValueBox<Int??> {
        let box = NIOLockedValueBox<Int??>(.none)
        Thread.detachNewThread {
            let r = gate.ask(prompt: "Use the GitHub token?", choices: ["Allow", "Deny"], timeout: timeout)
            box.withLockedValue { $0 = .some(r) }
        }
        return box
    }

    @Test func aPromptIsAnsweredOnTheUsersSideOnly() async throws {
        let user = Side(), guest = Side()
        let gate = ACAutomationServer.PumpConsentGate()
        let repainted = NIOLockedValueBox(0)
        let pump = Task {
            await ConsentPump.run(client: user.stream, toClient: { user.write($0) },
                                  guest: guest.stream, toGuest: { guest.write($0) },
                                  gate: gate, poll: .milliseconds(10),
                                  afterConsent: { repainted.withLockedValue { $0 += 1 } })
        }
        defer { pump.cancel() }
        user.send(Array("ls\r".utf8))
        guest.send(Array("$ ".utf8))
        try await Self.until(guest.bytes == Array("ls\r".utf8) && user.bytes == Array("$ ".utf8))
        #expect(guest.bytes == Array("ls\r".utf8) && user.bytes == Array("$ ".utf8), "a plain pump until asked")

        let answer = Self.ask(gate)
        let prompt = Screen.prompt("Use the GitHub token?", choices: ["Allow", "Deny"])
        try await Self.until(user.bytes.count >= 2 + prompt.count)
        #expect(Array(user.bytes.dropFirst(2)) == prompt)
        guest.send(Array("output meanwhile".utf8))
        try await Task.sleep(for: .milliseconds(100))
        #expect(user.bytes.count == 2 + prompt.count, "the guest's output waits while the prompt shows")

        user.send(Screen.frame(0, Array("2".utf8)))
        try await Self.until(answer.withLockedValue { $0 } != nil)
        #expect(answer.withLockedValue { $0 } == .some(1))
        try await Self.until(repainted.withLockedValue { $0 } == 1)
        #expect(repainted.withLockedValue { $0 } == 1)
        try await Self.until(user.bytes.count == 2 + prompt.count + Screen.clear.count + 16)
        #expect(Array(user.bytes.dropFirst(2 + prompt.count)) == Screen.clear + Array("output meanwhile".utf8),
                "cleared, then the guest's held output")
        #expect(guest.bytes == Array("ls\r".utf8), "the answer never reached the guest")

        user.send(Array("q".utf8))
        try await Self.until(guest.bytes.count == 4)
        #expect(guest.bytes == Array("ls\rq".utf8), "and the user's bytes flow again")
    }

    @Test func enterDeniesAndTheAttachEndingDeniesWhatsLeft() async throws {
        let user = Side(), guest = Side()
        let gate = ACAutomationServer.PumpConsentGate()
        let pump = Task {
            await ConsentPump.run(client: user.stream, toClient: { user.write($0) },
                                  guest: guest.stream, toGuest: { guest.write($0) },
                                  gate: gate, poll: .milliseconds(10))
        }
        let first = Self.ask(gate)
        try await Self.until(!user.bytes.isEmpty)
        user.send(Screen.frame(0, [0x0d]))
        try await Self.until(first.withLockedValue { $0 } != nil)
        #expect(first.withLockedValue { $0 } == .some(nil), "Enter denies")

        let second = Self.ask(gate)
        let prompt = Screen.prompt("Use the GitHub token?", choices: ["Allow", "Deny"])
        try await Self.until(user.bytes.count == 2 * prompt.count + Screen.clear.count)
        user.input.finish()            // the user's side ends
        await pump.value
        try await Self.until(second.withLockedValue { $0 } != nil)
        #expect(second.withLockedValue { $0 } == .some(nil))
        #expect(guest.bytes.isEmpty)
    }

    /// No gate (a GUI-fronted attach): every byte passes, digits included.
    @Test func withoutAGateItIsAPlainPump() async throws {
        let user = Side(), guest = Side()
        let pump = Task {
            await ConsentPump.run(client: user.stream, toClient: { user.write($0) },
                                  guest: guest.stream, toGuest: { guest.write($0) }, gate: nil)
        }
        defer { pump.cancel() }
        user.send(Screen.frame(0, Array("1".utf8)))
        guest.send(Array("hi".utf8))
        try await Self.until(guest.bytes.count == 6 && user.bytes.count == 2)
        #expect(guest.bytes == Screen.frame(0, Array("1".utf8)) && user.bytes == Array("hi".utf8))
    }

    /// The registry the consent brokers ask: an attach registered under the
    /// workspace's UUID is RemoteConsent's terminal route while it lasts, and
    /// its end denies what it was still asked.
    @Test func anAttachIsTheTerminalRouteWhileItLasts() async throws {
        let pid = UUID()
        let gate = ACAutomationServer.PumpConsentGate()
        #expect(!ACAutomationServer.isInteractivelyAttached(pid.uuidString))
        ACAutomationServer.registerGate(gate, for: pid.uuidString)
        #expect(ACAutomationServer.isInteractivelyAttached(pid.uuidString))
        if !PendingPromptBroker.hasLiveListener() { #expect(RemoteConsent.route(for: pid) == .terminalPump) }
        let asked = NIOLockedValueBox<Int??>(.none)
        Thread.detachNewThread {
            let r = RemoteConsent.choose(profileID: pid, title: "t", message: "m", choices: ["a"], timeoutSeconds: 30)
            asked.withLockedValue { $0 = .some(r) }
        }
        try await Self.until(gate.takePending() != nil)
        ACAutomationServer.unregisterGate(gate, for: pid.uuidString)
        try await Self.until(asked.withLockedValue { $0 } != nil)
        #expect(asked.withLockedValue { $0 } == .some(nil))
        #expect(!ACAutomationServer.isInteractivelyAttached(pid.uuidString))
    }
}
