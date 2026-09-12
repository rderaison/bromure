import Foundation
import Testing
@testable import bromure_ac

// omp's native `ask` tool requires a per-QUESTION id and options keyed by label
// (no option id); local models invert it, which omp rejects. These pin the fix
// against the exact payload from the field report.
@Suite("omp ask-tool normalization")
struct AskArgsNormalizerTests {

    // The "original" args from the reported failure: option ids present,
    // question ids missing.
    private func reportedArgs() -> [String: Any] {
        func opt(_ id: String, _ label: String) -> [String: Any] {
            ["id": id, "label": label, "description": "…"]
        }
        return [
            "questions": [
                ["header": "Protocols",
                 "question": "Which protocol surface must reach parity for your server fleet?",
                 "recommended": 0,
                 "options": [opt("scope_https", "HTTP/HTTPS only"),
                             opt("scope_plus_plain", "+ FTP, SMTP/IMAP/POP3"),
                             opt("scope_all", "Everything curl does")]],
                ["header": "Parity kind",
                 "question": "What does drop-in replacement concretely mean for you?",
                 "recommended": 0,
                 "options": [opt("parity_bin", "Binary-level"),
                             opt("parity_abi", "Binary + ABI"),
                             opt("parity_implicit", "Whatever is reasonable")]],
                ["header": "TLS strategy",
                 "question": "TLS strategy — the only place re-implementation loses security posture.",
                 "recommended": 1,
                 "options": [opt("tls_shim", "Thin native C shim"),
                             opt("tls_harness", "Reuse existing Rust HTTP/TLS harness"),
                             opt("tls_pure", "Pure Rust TLS from scratch")]],
            ]
        ]
    }

    @Test("Adds question ids, strips option ids, keeps label/description + recommended")
    func normalizesReportedPayload() {
        let out = AskArgsNormalizer.normalize(reportedArgs())
        let qs = out["questions"] as! [[String: Any]]
        #expect(qs.count == 3)

        // Every question now carries a non-empty id (slugged from the header).
        #expect(qs[0]["id"] as? String == "protocols")
        #expect(qs[1]["id"] as? String == "parity_kind")
        #expect(qs[2]["id"] as? String == "tls_strategy")

        // recommended index survives.
        #expect(qs[2]["recommended"] as? Int == 1)

        // Options keep label/description and NO id.
        for q in qs {
            for o in (q["options"] as! [[String: Any]]) {
                #expect(o["id"] == nil)
                #expect((o["label"] as? String)?.isEmpty == false)
                #expect(o["description"] != nil)
            }
        }
    }

    @Test("multiSelect is renamed to omp's multi; empty header falls back to q<n>")
    func multiAndFallbackId() {
        let args: [String: Any] = ["questions": [
            ["question": "Pick some", "multiSelect": true,
             "options": [["label": "A"], ["label": "B"]]],
        ]]
        let q = (AskArgsNormalizer.normalize(args)["questions"] as! [[String: Any]])[0]
        #expect(q["multi"] as? Bool == true)
        #expect(q["multiSelect"] == nil)
        // No header → id derived from the question text.
        #expect((q["id"] as? String)?.isEmpty == false)
    }

    @Test("Only a tool literally named `ask` is normalized — AskUserQuestion is untouched")
    func onlyAskToolInChat() throws {
        func chat(toolName: String) -> [String: Any] {
            let argJSON = String(data: try! JSONSerialization.data(withJSONObject: reportedArgs()), encoding: .utf8)!
            return ["choices": [["message": ["tool_calls": [
                ["type": "function", "function": ["name": toolName, "arguments": argJSON]]]]]]]
        }

        // ask → normalized (question ids appear in the serialized arguments).
        let asked = AskArgsNormalizer.normalizeChatMessage(chat(toolName: "ask"))
        let askArgs = (((asked["choices"] as! [[String: Any]])[0]["message"] as! [String: Any])["tool_calls"] as! [[String: Any]])[0]["function"] as! [String: Any]
        #expect((askArgs["arguments"] as! String).contains("\"id\":\"protocols\"")
                || (askArgs["arguments"] as! String).contains("\"protocols\""))

        // AskUserQuestion → returned byte-for-byte unchanged.
        let input = chat(toolName: "AskUserQuestion")
        let untouched = AskArgsNormalizer.normalizeChatMessage(input)
        let inArgs = (((input["choices"] as! [[String: Any]])[0]["message"] as! [String: Any])["tool_calls"] as! [[String: Any]])[0]["function"] as! [String: Any]
        let outArgs = (((untouched["choices"] as! [[String: Any]])[0]["message"] as! [String: Any])["tool_calls"] as! [[String: Any]])[0]["function"] as! [String: Any]
        #expect(inArgs["arguments"] as? String == outArgs["arguments"] as? String)
    }
}
