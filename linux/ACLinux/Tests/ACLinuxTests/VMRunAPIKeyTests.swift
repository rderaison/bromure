import Foundation
import Testing
@testable import ACLinux

/// `vm run --api-key`: on the command line (warned: other users of a
/// shared server see argv), `-` from stdin, else BROMURE_AC_API_KEY.
@Suite("vm run --api-key sources")
struct VMRunAPIKeyTests {
    @Test func theFlagStdinOrTheEnvironment() {
        let env = [VMRunAPIKey.environmentVariable: "from-env"]
        var read = 0
        let stdin = { () -> String? in read += 1; return "from-stdin\n" }
        let flag = VMRunAPIKey.resolve(flag: "on-argv", environment: env, stdin: stdin)
        #expect(flag.key == "on-argv" && flag.onCommandLine, "the flag wins, and is warned about")
        let piped = VMRunAPIKey.resolve(flag: "-", environment: env, stdin: stdin)
        #expect(piped.key == "from-stdin" && !piped.onCommandLine && read == 1, "trimmed, never warned")
        #expect(VMRunAPIKey.resolve(flag: "-", environment: [:], stdin: { "\n" }).key == nil, "empty stdin: none")
        let fromEnv = VMRunAPIKey.resolve(flag: nil, environment: env, stdin: stdin)
        #expect(fromEnv.key == "from-env" && !fromEnv.onCommandLine && read == 1, "stdin isn't read then")
        #expect(VMRunAPIKey.resolve(flag: nil, environment: [:], stdin: stdin).key == nil)
        #expect(VMRunAPIKey.argvWarning.contains("other users"))
    }
}
