import Foundation
import Testing
@testable import ACLinux

/// The Rampart PII classifier on onnxruntime's C API (macOS: its
/// Objective-C package). BROMURE_TEST_CLASSIFIER=1: the model under the
/// default models folder (XDG_DATA_HOME/BromureAC/Models/pii-rampart, as
/// scripts/fetch-pii-model.sh pins it) and onnxruntime present.
@Suite("PII classifier on Linux")
struct PIIDetectorLinuxTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BROMURE_TEST_CLASSIFIER"] == "1"))
    func theModelFindsNamesTheRecognizersCant() async throws {
        let d = PIIDetector.shared
        let text = "Thanks for the update. My name is Margaret Holloway and you can reach me at the office."
        let spans = await d.detect(text).spans
        #expect(await d.readiness() == .ready, "the model didn't load")
        let ns = text as NSString
        let found = spans.filter { !$0.heuristic }.map { ns.substring(with: NSRange(location: $0.start, length: $0.length)) }
        #expect(found.joined(separator: " ").contains("Margaret") && found.joined(separator: " ").contains("Holloway"), "\(found)")
        // No name in plain agent chatter (the caller's policy decides about
        // other labels).
        let chatter = await d.detect("The build finished in 42 seconds and all 186 tests passed.").spans
        #expect(!chatter.contains { $0.label == .givenName || $0.label == .surname }, "\(chatter)")
    }

    /// A long window: the model's output (a score per token and label) is
    /// past the C runtime's first buffer, read whole on the second run.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BROMURE_TEST_CLASSIFIER"] == "1"))
    func aLongWindowIsReadWhole() async throws {
        let filler = String(repeating: "The quarterly report covers revenue, costs and the hiring plan for next year. ", count: 20)
        let text = filler + "Please send it to Margaret Holloway before Friday."
        let ns = text as NSString
        let found = await PIIDetector.shared.detect(text).spans.filter { !$0.heuristic }
            .map { ns.substring(with: NSRange(location: $0.start, length: $0.length)) }
        #expect(found.joined(separator: " ").contains("Holloway"), "\(found)")
    }
}
