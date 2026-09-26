import Foundation
import Testing
@testable import bromure_ac

@Suite("PII recognizers")
struct PIIRecognizerTests {
    private func labels(_ s: String) -> [PIILabel] { PIIText.merge(PIIText.heuristics(s)).map(\.label) }

    @Test("A formatted SSN is found; a bare 9-digit constant only with context")
    func ssn() {
        #expect(labels("my ssn 472-81-0094 ok") == [.ssn])
        #expect(labels("let limit = 872411601") == [])
        #expect(labels("SSN: 472810094") == [.ssn])
        #expect(labels("area 900-12-3456") == [])            // never issued
    }

    @Test("Cards need Luhn and consistent separators; IPs aren't SSNs")
    func cards() {
        #expect(labels("card 4111 1111 1111 1111") == [.creditCard])
        #expect(labels("card 4111 1111 1111 1112") == [])
        #expect(labels("host 192.168.64.0") == [.ipAddress])
    }

    @Test("Emails and URLs by pattern")
    func text() {
        #expect(labels("mail alex.rivera+x@gmail.com now") == [.email])
        #expect(labels("see https://example.com/a?b=1") == [.url])
    }

    @Test("Premask projects model spans back onto the raw text")
    func premask() {
        let raw = "Mail bob@x.io then Alex"
        let m = PIIText.premask(raw, PIIText.heuristics(raw))
        #expect(m.text == "Mail [EMAIL] then Alex")
        let alex = (m.text as NSString).range(of: "Alex")
        let p = m.project(PIISpan(start: alex.location, end: NSMaxRange(alex), label: .givenName, score: 1, heuristic: false))
        #expect(p.map { (raw as NSString).substring(with: NSRange(location: $0.start, length: $0.length)) } == "Alex")
    }

    @Test("Code is gated out of the model pass; data and prose aren't")
    func codeGate() {
        let code = String(repeating: "func f(x: Int) -> Int {\n    let y = x + 1;\n    return y\n}\n", count: 30)
        #expect(PIIText.proseRanges(code).isEmpty)
        let json = String(repeating: "  {\n    \"name\": \"Alex Rivera\",\n    \"email\": \"a@b.com\"\n  },\n", count: 30)
        #expect(PIIText.proseRanges(json).count == 1)
        #expect(PIIText.proseRanges("Please call Alex Rivera tomorrow about the invoice.").count == 1)
    }
}

@Suite("PII tokenizer")
struct PIITokenizerTests {
    private let wp = PIIText.WordPiece(vocab: [
        "[PAD]": 0, "[UNK]": 1, "[CLS]": 2, "[SEP]": 3, "hello": 4, ",": 5, "jose": 6, "!": 7,
        "gar": 8, "##cia": 9, "x": 10,
    ])

    @Test("Folded WordPiece keeps each token's source range")
    func offsets() {
        let text = "Hello, José García!"
        let toks = wp.tokenize(text)
        let ns = text as NSString
        #expect(toks.map(\.id) == [4, 5, 6, 8, 9, 7])
        #expect(toks.map { ns.substring(with: NSRange(location: $0.start, length: $0.end - $0.start)) }
                == ["Hello", ",", "José", "Gar", "cía", "!"])
        #expect(toks.map(\.isSubword) == [false, false, false, false, true, false])
    }

    @Test("Unknown words become one [UNK]")
    func unknown() {
        #expect(wp.tokenize("zzz").map(\.id) == [1])
    }

    @Test("Windows cover everything, overlap, and never start mid-word")
    func windows() {
        let toks = (0..<1300).map { i in PIIText.Token(id: 10, start: i, end: i + 1, isSubword: i % 3 == 2) }
        let ws = PIIText.windows(toks, budget: 500, overlap: 64)
        #expect(ws.first?.lowerBound == 0)
        #expect(ws.last?.upperBound == toks.count)
        for (a, b) in zip(ws, ws.dropFirst()) {
            #expect(b.lowerBound < a.upperBound)          // overlap
            #expect(!toks[b.lowerBound].isSubword)
        }
        #expect(ws.allSatisfy { $0.count <= 500 })
    }

    @Test("BIO tags merge into entities; subwords always extend")
    func bio() {
        func t(_ i: Int, _ l: PIILabel, _ b: Bool, _ s: Int, _ e: Int, sub: Bool = false) -> PIIText.Tagged {
            .init(index: i, label: l, begins: b, score: 0.9, start: s, end: e, isSubword: sub)
        }
        let spans = PIIText.mergeBIO([
            t(0, .givenName, true, 0, 4), t(1, .surname, true, 5, 8), t(2, .surname, true, 8, 12, sub: true),
            t(5, .surname, false, 20, 24),
        ])
        #expect(spans.map { [$0.start, $0.end] } == [[0, 4], [5, 12], [20, 24]])
    }
}

@Suite("PII vault")
struct PIIVaultTests {
    private let secret = Data(repeating: 7, count: 32)

    @Test("Stand-ins are stable per key and look like the real thing")
    func deterministic() {
        let a = PIIVault(secret: secret), b = PIIVault(secret: secret)
        let e1 = a.learn("Alex", label: .givenName)
        #expect(b.learn("Alex", label: .givenName).surrogate == e1.surrogate)
        #expect(e1.surrogate != "Alex" && e1.surrogate.first!.isUppercase)
        #expect(a.learn("bob@corp.com", label: .email).surrogate.hasSuffix("@example.com"))
        let ssn = a.learn("472-81-0094", label: .ssn).surrogate
        #expect(ssn.hasPrefix("9") && ssn.count == 11 && ssn.filter { $0 == "-" }.count == 2)
        let card = a.learn("4111 1111 1111 1111", label: .creditCard).surrogate
        #expect(PIIText.isLuhnValid(card.compactMap { $0.wholeNumberValue.map(UInt8.init) }))
        #expect(PIIVault(secret: Data(repeating: 9, count: 32)).learn("Alex", label: .givenName).surrogate != e1.surrogate)
    }

    @Test("Forward swaps spans and every other sighting; restore inverts, casing included")
    func roundTrip() {
        let v = PIIVault(secret: secret)
        let text = "Rivera called. RIVERA said rivera_account is Rivera's."
        let r = (text as NSString).range(of: "Rivera")
        let (out, n) = v.forward(text, spans: [PIISpan(start: r.location, end: NSMaxRange(r), label: .surname, score: 1, heuristic: false)])
        #expect(n == 4)
        #expect(!out.lowercased().contains("rivera"))
        #expect(v.restore(out) == text)
    }

    @Test("A name that's also a word is swapped only where it was detected")
    func commonWord() {
        let v = PIIVault(secret: secret)
        let text = "Will Smith will call."
        let (out, n) = v.forward(text, spans: [PIISpan(start: 0, end: 4, label: .givenName, score: 1, heuristic: false)])
        #expect(n == 1)
        #expect(out.hasSuffix(" Smith will call."))
    }

    @Test("Hold-back keeps a split stand-in until it's whole")
    func holdback() {
        let v = PIIVault(secret: secret)
        let s = v.learn("Alexandra", label: .givenName).surrogate
        let head = "Hello " + String(s.prefix(3))
        #expect(v.holdback(head) == 6)
        #expect(v.holdback("Hello world") == 11)
        #expect(v.holdback("Hi " + s) == 3)        // whole, but a longer word may follow
    }

    @Test("Restored values are JSON-escaped inside tool-call JSON")
    func jsonFragment() {
        let v = PIIVault(secret: secret)
        let s = v.learn("O\"Neil", label: .surname).surrogate
        #expect(v.restore("{\"who\":\"\(s)\"}", jsonFragment: true) == "{\"who\":\"O\\\"Neil\"}")
    }
}

@Suite("PII request / response")
struct PIIWireTests {
    private let secret = Data(repeating: 3, count: 32)

    @Test("The JSON walker finds values with their keys, arrays inherit")
    func scan() {
        let b = Array(#"{"model":"x","messages":[{"role":"user","content":["a\"b","c"]}]}"#.utf8)
        let refs = JSONStrings.scan(b)!
        #expect(refs.map(\.key) == ["model", "role", "content", "content"])
        #expect(JSONStrings.decode(b, refs[2].range) == "a\"b")
    }

    @Test("A request is rewritten string by string; thinking and signatures untouched")
    func request() async {
        let vault = PIIVault(secret: secret)
        let body = #"{"model":"claude","messages":[{"role":"assistant","content":[{"type":"thinking","thinking":"mail bob@corp.com","signature":"sig"}]},{"role":"user","content":"Write to bob@corp.com please"}],"temperature":0.70}"#
        let o = await PIIRewriter.rewriteRequest(Data(body.utf8), policy: PIIPolicy(enabled: true), vault: vault)
        let out = String(decoding: o.body, as: UTF8.self)
        let sub = vault.learn("bob@corp.com", label: .email).surrogate
        #expect(out.contains(#""thinking":"mail bob@corp.com""#))
        #expect(out.contains("Write to \(sub) please"))
        #expect(out.hasSuffix(#""temperature":0.70}"#))       // untouched bytes stay as sent
        #expect(o.newSwaps[.email] == 1)
        // Resent next turn: same bytes, nothing new to count.
        let again = await PIIRewriter.rewriteRequest(Data(body.utf8), policy: PIIPolicy(enabled: true), vault: vault)
        #expect(again.body == o.body)
        #expect(again.total == 0)
    }

    @Test("Code-shaped names and file names aren't swapped")
    func plan() {
        #expect(!PIIRewriter.isPlausibleName("hexInUI"))
        #expect(!PIIRewriter.isPlausibleName("NIOSSHHandler"))
        #expect(!PIIRewriter.isPlausibleName("Claude"))
        #expect(PIIRewriter.isPlausibleName("McDonald"))
        #expect(PIIRewriter.isPlausibleName("van der Berg"))
        #expect(!PIIRewriter.isPlausibleEmail("icon@2x.png"))
        #expect(!PIIRewriter.isPlausibleIdentifier("2147483647"))
    }

    private func sse(_ events: [String]) -> Data {
        Data(events.map { "event: x\ndata: \($0)\n\n" }.joined().utf8)
    }

    @Test("Anthropic stream: a stand-in split across deltas comes back whole; thinking passes")
    func anthropicStream() {
        let vault = PIIVault(secret: secret)
        let s = vault.learn("Alexandra", label: .givenName).surrogate
        let r = PIIResponseRestorer(vault: vault, contentType: "text/event-stream")
        let mid = s.count / 2
        var out = r.feed(sse([
            #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"\#(s)"}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Hi \#(s.prefix(mid))"}}"#,
        ]))
        out += r.feed(sse([
            #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"\#(s.dropFirst(mid)), bye"}}"#,
            #"{"type":"content_block_stop","index":1}"#,
        ]))
        out += r.finish()
        var text = ""
        var thinking = ""
        for line in String(decoding: out, as: UTF8.self).components(separatedBy: "\n") where line.hasPrefix("data: ") {
            let o = try! JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8)) as! [String: Any]
            if let d = o["delta"] as? [String: Any] {
                text += d["text"] as? String ?? ""
                thinking += d["thinking"] as? String ?? ""
            }
        }
        #expect(text == "Hi Alexandra, bye")
        #expect(thinking == s)
    }

    @Test("A held tail is released before the block stops")
    func flushOrder() {
        let vault = PIIVault(secret: secret)
        let s = vault.learn("Alexandra", label: .givenName).surrogate
        let r = PIIResponseRestorer(vault: vault, contentType: "text/event-stream")
        let out = String(decoding: r.feed(sse([
            #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Bye \#(s)"}}"#,
            #"{"type":"content_block_stop","index":0}"#,
        ])), as: UTF8.self)
        let alexandra = out.range(of: "Alexandra")!
        let stop = out.range(of: "content_block_stop")!
        #expect(alexandra.lowerBound < stop.lowerBound)
    }

    @Test("OpenAI chat stream restores and releases at finish_reason")
    func chatStream() {
        let vault = PIIVault(secret: secret)
        let s = vault.learn("bob@corp.com", label: .email).surrogate
        let r = PIIResponseRestorer(vault: vault, contentType: "text/event-stream; charset=utf-8")
        var out = r.feed(sse([
            #"{"object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"mail \#(s.prefix(4))"}}]}"#,
            #"{"object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"\#(s.dropFirst(4))"},"finish_reason":"stop"}]}"#,
        ]))
        out += r.feed(Data("data: [DONE]\n\n".utf8)) + r.finish()
        var text = ""
        for line in String(decoding: out, as: UTF8.self).components(separatedBy: "\n") where line.hasPrefix("data: {") {
            let o = try! JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8)) as! [String: Any]
            let c = (o["choices"] as! [[String: Any]])[0]
            text += (c["delta"] as? [String: Any])?["content"] as? String ?? ""
        }
        #expect(text == "mail bob@corp.com")
    }

    @Test("A plain JSON reply is restored whole")
    func jsonBody() {
        let vault = PIIVault(secret: secret)
        let s = vault.learn("Alexandra", label: .givenName).surrogate
        let r = PIIResponseRestorer(vault: vault, contentType: "application/json")
        var out = r.feed(Data(#"{"content":[{"type":"text","text":"Dear \#(s)"}],"#.utf8))
        out += r.feed(Data(#""signature":"\#(s)"}"#.utf8))
        out += r.finish()
        #expect(String(decoding: out, as: UTF8.self) == #"{"content":[{"type":"text","text":"Dear Alexandra"}],"signature":"\#(s)"}"#)
    }
}
