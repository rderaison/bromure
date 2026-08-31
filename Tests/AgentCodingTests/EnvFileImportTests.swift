import Foundation
import Testing
@testable import bromure_ac

/// Coverage for `EnvFileImport` — the `.env` / shell-file recognizer that maps
/// variable names to typed credential slots. Focused on the Twilio slots and
/// the two-component reassembly they share with AWS, plus the parser's refusal
/// to evaluate shell.
@Suite("EnvFileImport")
struct EnvFileImportTests {

    @Test("Twilio SID + secret names route to their slots")
    func twilioSlots() {
        #expect(EnvFileImport.slot(forName: "TWILIO_ACCOUNT_SID") == .twilioSID)
        #expect(EnvFileImport.slot(forName: "TWILIO_API_KEY_SID") == .twilioSID)
        #expect(EnvFileImport.slot(forName: "TWILIO_AUTH_TOKEN") == .twilioSecret)
        #expect(EnvFileImport.slot(forName: "TWILIO_API_SECRET") == .twilioSecret)
        // Case-insensitive (the recognizer uppercases).
        #expect(EnvFileImport.slot(forName: "twilio_auth_token") == .twilioSecret)
    }

    @Test("Twilio slots scope to twilio.com and carry human labels")
    func twilioHostsAndNames() {
        #expect(EnvFileImport.hosts(for: .twilioSID) == ["twilio.com"])
        #expect(EnvFileImport.hosts(for: .twilioSecret) == ["twilio.com"])
        #expect(EnvFileImport.displayName(for: .twilioSID) == "Twilio SID")
        #expect(EnvFileImport.displayName(for: .twilioSecret) == "Twilio auth token")
    }

    @Test("A .env with both halves classifies as two recognized Twilio rows")
    func classifyTwilioEnv() {
        let env = """
        # Twilio
        export TWILIO_ACCOUNT_SID=ACdeadbeefdeadbeefdeadbeefdeadbeef
        TWILIO_AUTH_TOKEN="0123456789abcdef0123456789abcdef"
        """
        let c = EnvFileImport.classify(EnvFileImport.parse(env))
        #expect(c.unrecognized.isEmpty)
        let slots = c.recognized.map { $0.slot }
        #expect(slots.contains(.twilioSID))
        #expect(slots.contains(.twilioSecret))
        let secret = c.recognized.first { $0.slot == .twilioSecret }?.variable.value
        #expect(secret == "0123456789abcdef0123456789abcdef")
    }

    @Test("An interpolated Twilio value is skipped, not imported wrong")
    func refusesInterpolation() {
        let env = "TWILIO_AUTH_TOKEN=$SECRET_FROM_ELSEWHERE\n"
        // The value needs shell to resolve, so parse drops it entirely.
        #expect(EnvFileImport.parse(env).isEmpty)
    }
}
