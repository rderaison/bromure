import Foundation
import Testing
@testable import bromure_ac

/// QA round (Claude + omp): a lone "Blue" swapped as a name, a street address
/// that went out unswapped, and a 200 KB paste that took 10.5 s to scan.
@Suite("PII QA fixes")
struct PIIQAFixesTests {
    private func kept(_ text: String, _ needle: String, _ label: PIILabel = .givenName, score: Double) -> Bool {
        let r = (text as NSString).range(of: needle)
        precondition(r.location != NSNotFound, needle)
        let span = PIISpan(start: r.location, end: NSMaxRange(r), label: label, score: score, heuristic: false)
        return !PIIRewriter.plan([span], in: text, policy: PIIPolicy(enabled: true)).isEmpty
    }

    // MARK: Lone common words

    @Test("A lone color / day / answer word is not a name, however sure the model is")
    func loneCommonWords() {
        // The model scored "Blue" 0.99 here (measured with the bundled Rampart model).
        #expect(!kept("line 2 says Blue", "Blue", score: 0.99))
        #expect(!kept("Blue", "Blue", score: 0.99))
        #expect(!kept("# cc-demo\nBlue\n\nA tiny Python module used for testing.\n", "Blue", score: 0.95))
        #expect(!kept(#"User has answered your questions: "What is your favorite color?"="Blue"."#, "Blue", score: 0.9))
        #expect(!kept("Pick one: Navy Blue", "Navy Blue", score: 0.95))
        #expect(!kept("Due Friday", "Friday", score: 0.95))
        #expect(!kept("See you in June", "June", score: 0.95))
        #expect(!kept("Answer: Yes", "Yes", score: 0.95))
    }

    @Test("Names still get through: full names, introduced lone words, sure short names")
    func realNamesStillSwapped() {
        #expect(kept("My customer is Margaret Holloway", "Margaret Holloway", score: 0.9))
        #expect(kept("Please email Mr Brown today", "Brown", .surname, score: 0.9))
        #expect(kept("Dear Grace, thanks for the report.", "Grace", score: 0.9))
        #expect(kept("The meeting is with June tomorrow", "June", score: 0.9))
        #expect(kept("The ticket was filed by Bob yesterday.", "Bob", score: 0.93))
        #expect(kept("Hollowell signed off", "Hollowell", .surname, score: 0.7))
        // Introduced, but the model isn't sure a dictionary word is a name.
        #expect(!kept("Dear Will, thanks", "Will", score: 0.6))
        // A short unknown token with neither confidence nor context.
        #expect(!kept("ran Kai again", "Kai", score: 0.6))
    }

    // MARK: Addresses

    private func streets(_ s: String) -> [String] {
        let ns = s as NSString
        return PIIText.heuristics(s).filter { $0.label == .streetName }
            .map { ns.substring(with: NSRange(location: $0.start, length: $0.length)) }
    }

    @Test("Street lines are found without the model")
    func streetRecognizer() {
        #expect(streets("Jane Q. Example, jane.example@contoso-test.org, +1 415 555 0137, 42 Example Street, Springfield")
                == ["42 Example Street"])
        #expect(streets("     1\tJane Q. Example, 42 Example Street, Springfield\n") == ["42 Example Street"])
        #expect(streets("living at 1427 Juniper Hollow Rd. in Portland") == ["1427 Juniper Hollow Rd."])
        #expect(streets("ship to 10B Main St, Apt 4, Boston") == ["10B Main St, Apt 4"])
        #expect(streets("Lieferung an Hauptstraße 5, Berlin") == ["Hauptstraße 5"])
        #expect(streets("au 12 rue de la Paix, Paris") == ["12 rue de la Paix"])
        // Not addresses.
        #expect(streets("added 18 new keys to the catalog").isEmpty)
        #expect(streets("HTTP/1.1 200 OK").isEmpty)
        #expect(streets("let street = 42\nStreet lights").isEmpty)
        #expect(streets("Step 2 Drive Setup").isEmpty)
        #expect(streets("see issue #42 Example Street").isEmpty)
    }

    @Test("An address in an omp-shaped tool output is swapped; the city stays")
    func addressSwappedInRequest() async throws {
        let line = "Jane Q. Example, jane.example@contoso-test.org, +1 415 555 0137, 42 Example Street, Springfield"
        let msgs: [[String: Any]] = [
            ["role": "user", "content": "Read contacts.txt"],
            ["role": "assistant", "content": "", "tool_calls": [["id": "call_1", "type": "function",
                "function": ["name": "bash", "arguments": #"{"command":"cat contacts.txt"}"#]]]],
            ["role": "tool", "tool_call_id": "call_1", "content": line + "\n"],
        ]
        let body = try JSONSerialization.data(withJSONObject: ["model": "x", "messages": msgs, "stream": true])
        let vault = PIIVault(secret: Data(repeating: 7, count: 32))
        let o = await PIIRewriter.rewriteRequest(body, policy: PIIPolicy(enabled: true), vault: vault,
                                                 detector: PIIDetector())
        let out = String(decoding: o.body, as: UTF8.self)
        #expect(!out.contains("42 Example Street"))
        #expect(!out.contains("jane.example@contoso-test.org"))
        #expect(out.contains("Springfield"))
    }

    // MARK: Speed

    @Test("A word that shatters into many pieces is one [UNK]; real words tokenize as before")
    func gibberishWordIsOneUnk() {
        var vocab: [String: Int32] = ["[PAD]": 0, "[UNK]": 1, "[CLS]": 2, "[SEP]": 3, "gar": 4, "##cia": 5, "hello": 6]
        var id: Int32 = 10
        for c in "abcdefghijklmnopqrstuvwxyz" { vocab[String(c)] = id; vocab["##" + String(c)] = id + 1; id += 2 }
        let wp = PIIText.WordPiece(vocab: vocab)
        #expect(wp.maxPieceScalars == 5)   // "##cia", "hello"
        let junk = "ihubdkxwiwbiurvnvzqijugcqafihxgfxkgmkthmuwvrppqwaanxhsjzgmts"
        let toks = wp.tokenize("P00001 \(junk) hello")
        let ns = "P00001 \(junk) hello" as NSString
        let last2 = toks.suffix(2).map { ns.substring(with: NSRange(location: $0.start, length: $0.end - $0.start)) }
        #expect(last2 == [junk, "hello"])
        #expect(toks[toks.count - 2].id == 1)
        // A name of a few pieces is untouched.
        #expect(wp.tokenize("García").map(\.id) == [4, 5])
        #expect(wp.tokenize("abc").map(\.id) == [10, 13, 15])
    }

    @Test("Content-defined chunks cover the text and survive an append or an edit elsewhere")
    func contentChunksAreStable() {
        var text = ""
        for i in 0..<3000 { text += "Line \(i): some ordinary log text with a value \(i * 7919 % 1000)\n" }
        let ns = text as NSString
        let a = PIIText.contentChunks(text)
        #expect(a.count > 4)
        #expect(a.first?.lowerBound == 0 && a.last?.upperBound == ns.length)
        for (x, y) in zip(a, a.dropFirst()) { #expect(x.upperBound == y.lowerBound) }
        for r in a.dropLast() { #expect(ns.character(at: r.upperBound - 1) == 0x0A) }
        // Appending keeps every chunk but the last.
        let b = PIIText.contentChunks(text + "Appended by Jane Example\n")
        #expect(Array(b.prefix(a.count - 1)) == Array(a.dropLast()))
        // An edit near the start: the chunks re-sync, most of the tail is shared.
        let edited = "EDITED " + text
        let c = PIIText.contentChunks(edited)
        let pieces = Set(a.map { ns.substring(with: NSRange(location: $0.lowerBound, length: $0.count)) })
        let ens = edited as NSString
        let shared = c.filter { pieces.contains(ens.substring(with: NSRange(location: $0.lowerBound, length: $0.count))) }
        #expect(shared.count >= a.count - 3)
        // Short text: one chunk.
        #expect(PIIText.contentChunks("short") == [0..<5])
        #expect(PIIText.contentChunks("").isEmpty)
    }

    @Test("A grown string only charges its new chunks to the model budget")
    func incrementalDetection() async {
        let detector = PIIDetector()
        var text = ""
        for i in 0..<3000 { text += "Entry \(i): contact sales at sales\(i)@example.org for the quote.\n" }
        let first = await detector.detectIncremental(text)
        #expect(!first.cached)
        #expect(first.modelUnits == text.utf16.count)
        let grown = text + "New entry: write to margaret@example.net\n"
        let second = await detector.detectIncremental(grown)
        #expect(!second.cached)
        #expect(second.modelUnits > 0 && second.modelUnits < 9000)
        // Spans keep whole-text offsets: the new email is found where it is.
        let ns = grown as NSString
        #expect(second.spans.contains { $0.label == .email
            && ns.substring(with: NSRange(location: $0.start, length: $0.length)) == "margaret@example.net" })
        #expect(second.spans.filter { $0.label == .email }.count == 3001)
        let third = await detector.detectIncremental(grown)
        #expect(third.cached && third.modelUnits == 0)
    }
}
