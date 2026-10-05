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

    // MARK: Kimi / OpenAI chat: tool-call arguments and escapes

    private func chatEvents(_ out: Data) -> [[String: Any]] {
        String(decoding: out, as: UTF8.self).components(separatedBy: "\n")
            .filter { $0.hasPrefix("data: {") }
            .map { try! JSONSerialization.jsonObject(with: Data($0.dropFirst(6).utf8)) as! [String: Any] }
    }

    @Test("Kimi stream: tool-call arguments split mid stand-in and after \\n escapes are restored")
    func kimiToolCallStream() throws {
        let vault = PIIVault(secret: secret)
        let name = vault.learn("Margaret", label: .givenName).surrogate
        let mail = vault.learn("margaret.holloway@example.org", label: .email).surrogate
        let phone = vault.learn("+1 415 555 0142", label: .phone).surrogate
        let r = PIIResponseRestorer(vault: vault, contentType: "text/event-stream")
        // The arguments JSON as the model writes it, cut into small fragments
        // at awkward places (inside stand-ins, inside the `\n` escape).
        let args = #"{"path":"/home/ubuntu/s2pii.txt","content":"\#(name)\n\#(mail)\n\#(phone)\n"}"#
        var pieces: [String] = []
        var rest = Substring(args)
        var size = 3
        while !rest.isEmpty { pieces.append(String(rest.prefix(size))); rest = rest.dropFirst(size); size = size % 7 + 2 }
        func ev(_ obj: [String: Any]) -> String {
            String(decoding: try! JSONSerialization.data(withJSONObject: obj), as: UTF8.self)
        }
        var events = [ev(["object": "chat.completion.chunk", "choices": [["index": 0, "delta": [
            "role": "assistant", "content": "",
            "tool_calls": [["index": 0, "id": "WriteFile:0", "type": "function",
                            "function": ["name": "WriteFile", "arguments": ""]]]]]]])]
        for p in pieces {
            events.append(ev(["object": "chat.completion.chunk", "choices": [["index": 0, "finish_reason": NSNull(), "delta": [
                "tool_calls": [["index": 0, "function": ["arguments": p]]]]]]]))
        }
        events.append(ev(["object": "chat.completion.chunk", "choices": [["index": 0, "delta": [:], "finish_reason": "tool_calls"]]]))
        events.append(ev(["object": "chat.completion.chunk", "choices": [], "usage": ["total_tokens": 9]]))
        var out = Data()
        // Feed in odd byte slices, as the network would.
        let wire = Data(events.map { "data: \($0)\n\n" }.joined().utf8) + Data("data: [DONE]\n\n".utf8)
        var i = 0
        while i < wire.count { out += r.feed(wire.subdata(in: i..<min(wire.count, i + 37))); i += 37 }
        out += r.finish()
        var joined = ""
        for o in chatEvents(out) {
            for c in o["choices"] as? [[String: Any]] ?? [] {
                for t in (c["delta"] as? [String: Any])?["tool_calls"] as? [[String: Any]] ?? [] {
                    joined += (t["function"] as? [String: Any])?["arguments"] as? String ?? ""
                }
            }
        }
        let parsed = try JSONSerialization.jsonObject(with: Data(joined.utf8)) as! [String: String]
        #expect(parsed["content"] == "Margaret\nmargaret.holloway@example.org\n+1 415 555 0142\n")
    }

    @Test("Kimi stream: reply text and visible reasoning are restored")
    func kimiTextAndReasoning() {
        let vault = PIIVault(secret: secret)
        let s = vault.learn("Holloway", label: .surname).surrogate
        let r = PIIResponseRestorer(vault: vault, contentType: "text/event-stream; charset=utf-8")
        var out = r.feed(Data(("data: {\"choices\":[{\"index\":0,\"delta\":{\"reasoning_content\":\"user is \(s.prefix(2))\"}}]}\n\n"
            + "data: {\"choices\":[{\"index\":0,\"delta\":{\"reasoning_content\":\"\(s.dropFirst(2))\"}}]}\n\n"
            + "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Dear Ms \(s.prefix(3))\"}}]}\n\n"
            + "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"\(s.dropFirst(3))\\nbye\"}}]}\n\n"
            + "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n").utf8))
        out += r.finish()
        var text = "", reasoning = ""
        for o in chatEvents(out) {
            let d = ((o["choices"] as! [[String: Any]])[0]["delta"] as? [String: Any]) ?? [:]
            text += d["content"] as? String ?? ""
            reasoning += d["reasoning_content"] as? String ?? ""
        }
        #expect(text == "Dear Ms Holloway\nbye")
        #expect(reasoning == "user is Holloway")
    }

    @Test("Non-streaming chat reply: tool-call arguments restored inside their JSON")
    func chatJSONArguments() throws {
        let vault = PIIVault(secret: secret)
        let mail = vault.learn("o\"neil@corp.com", label: .email).surrogate
        let name = vault.learn("Alexandra", label: .givenName).surrogate
        let args = #"{"content":"\#(name)\n\#(mail)"}"#
        let body: [String: Any] = ["choices": [["index": 0, "message": [
            "role": "assistant", "content": "Wrote it for \(name).",
            "tool_calls": [["id": "c1", "type": "function", "function": ["name": "WriteFile", "arguments": args]]]]]]]
        let r = PIIResponseRestorer(vault: vault, contentType: "application/json")
        var out = r.feed(try JSONSerialization.data(withJSONObject: body))
        out += r.finish()
        let o = try JSONSerialization.jsonObject(with: out) as! [String: Any]
        let msg = (o["choices"] as! [[String: Any]])[0]["message"] as! [String: Any]
        #expect(msg["content"] as? String == "Wrote it for Alexandra.")
        let call = (msg["tool_calls"] as! [[String: Any]])[0]["function"] as! [String: Any]
        let inner = try JSONSerialization.jsonObject(with: Data((call["arguments"] as! String).utf8)) as! [String: String]
        #expect(inner["content"] == "Alexandra\no\"neil@corp.com")
    }

    @Test("Anthropic input_json_delta: a stand-in after an escaped newline, split across deltas")
    func anthropicToolInput() throws {
        let vault = PIIVault(secret: secret)
        let mail = vault.learn("bob@corp.com", label: .email).surrogate
        let r = PIIResponseRestorer(vault: vault, contentType: "text/event-stream")
        let raw = #"{"text":"hi\n\#(mail)"}"#
        let cut1 = raw.index(raw.startIndex, offsetBy: 11)        // inside "\n"
        let cut2 = raw.index(cut1, offsetBy: 5)
        func delta(_ p: Substring) -> String {
            let o: [String: Any] = ["type": "content_block_delta", "index": 1,
                                    "delta": ["type": "input_json_delta", "partial_json": String(p)]]
            return String(decoding: try! JSONSerialization.data(withJSONObject: o), as: UTF8.self)
        }
        var out = r.feed(sse([delta(raw[..<cut1]), delta(raw[cut1..<cut2])]))
        out += r.feed(sse([delta(raw[cut2...]), #"{"type":"content_block_stop","index":1}"#]))
        out += r.finish()
        var json = ""
        for o in chatEvents(out) { json += ((o["delta"] as? [String: Any])?["partial_json"] as? String) ?? "" }
        let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: String]
        #expect(parsed["text"] == "hi\nbob@corp.com")
    }

    @Test("Responses API: function-call argument deltas and the .done event are restored")
    func responsesArguments() throws {
        let vault = PIIVault(secret: secret)
        let name = vault.learn("Alexandra", label: .givenName).surrogate
        let r = PIIResponseRestorer(vault: vault, contentType: "text/event-stream")
        let raw = #"{"cmd":"echo\n\#(name)"}"#
        let mid = raw.index(raw.startIndex, offsetBy: raw.count - 5)
        func d(_ p: Substring) -> String {
            let o: [String: Any] = ["type": "response.function_call_arguments.delta", "item_id": "fc_1", "output_index": 0, "delta": String(p)]
            return String(decoding: try! JSONSerialization.data(withJSONObject: o), as: UTF8.self)
        }
        let done: [String: Any] = ["type": "response.function_call_arguments.done", "item_id": "fc_1", "arguments": raw]
        var out = r.feed(sse([d(raw[..<mid]), d(raw[mid...])]))
        out += r.feed(sse([String(decoding: try JSONSerialization.data(withJSONObject: done), as: UTF8.self)]))
        out += r.finish()
        var streamed = ""
        var final = ""
        for o in chatEvents(out) {
            if o["type"] as? String == "response.function_call_arguments.delta" { streamed += o["delta"] as? String ?? "" }
            if o["type"] as? String == "response.function_call_arguments.done" { final = o["arguments"] as? String ?? "" }
        }
        let want = #"{"cmd":"echo\nAlexandra"}"#
        #expect(streamed == want)
        #expect(final == want)
    }

    @Test("Request: tool-call arguments swap per inner string; one stand-in per value")
    func requestArguments() async throws {
        let vault = PIIVault(secret: secret)
        let mail = "margaret.holloway@example.org"
        let args = #"{"path":"/tmp/x","content":"Hello\n\#(mail)\n"}"#
        let msgs: [[String: Any]] = [
            ["role": "user", "content": "Write \(mail) to a file"],
            ["role": "assistant", "content": "", "tool_calls": [["id": "c1", "type": "function",
                "function": ["name": "WriteFile", "arguments": args]]]],
            ["role": "tool", "tool_call_id": "c1", "content": "wrote 2 lines"],
        ]
        let body = try JSONSerialization.data(withJSONObject: ["model": "kimi", "messages": msgs])
        let o = await PIIRewriter.rewriteRequest(body, policy: PIIPolicy(enabled: true), vault: vault)
        let out = try JSONSerialization.jsonObject(with: o.body) as! [String: Any]
        let m = out["messages"] as! [[String: Any]]
        let sub = vault.learn(mail, label: .email).surrogate
        #expect(m[0]["content"] as? String == "Write \(sub) to a file")
        let a = ((m[1]["tool_calls"] as! [[String: Any]])[0]["function"] as! [String: Any])["arguments"] as! String
        let inner = try JSONSerialization.jsonObject(with: Data(a.utf8)) as! [String: String]
        #expect(inner["content"] == "Hello\n\(sub)\n")
        #expect(!String(decoding: o.body, as: UTF8.self).contains("nmargaret"))
    }

    @Test("A stand-in echoed back by the agent is never learned as a new value")
    func surrogateNotRelearned() async throws {
        let vault = PIIVault(secret: secret)
        let sub = vault.learn("margaret.holloway@example.org", label: .email).surrogate
        let body = try JSONSerialization.data(withJSONObject: ["model": "k", "messages": [
            ["role": "user", "content": "the file says \(sub)"]]])
        let o = await PIIRewriter.rewriteRequest(body, policy: PIIPolicy(enabled: true), vault: vault)
        #expect(o.body == body)
        #expect(o.total == 0)
        #expect(vault.restore(sub) == "margaret.holloway@example.org")
    }
}

@Suite("PII false positives in agent traffic")
struct PIIFalsePositiveTests {
    private func kept(_ text: String, _ needle: String, _ label: PIILabel, score: Double = 0.95) -> Bool {
        let r = (text as NSString).range(of: needle)
        precondition(r.location != NSNotFound, needle)
        let span = PIISpan(start: r.location, end: NSMaxRange(r), label: label, score: score, heuristic: false)
        return !PIIRewriter.plan([span], in: text, policy: PIIPolicy(enabled: true)).isEmpty
    }

    @Test("Hashes, UUID pieces, generated ids and timestamps are not ID numbers or phones")
    func noFalseIDs() {
        let uuid = "Session ec0b1592-369c-4f63-b5af-174c02268e1d resumed"
        #expect(!kept(uuid, "174c02268e1d", .driversLicense))
        #expect(!kept(uuid, "369c-4f63", .governmentID))
        #expect(!kept("commit 53ABE468 fixes the build", "53ABE468", .passport))
        #expect(!kept("HEAD is now at 8ff43487 Fix session-scoped queues", "8ff43487", .governmentID))
        #expect(!kept("job id b3p1d0w0o finished", "b3p1d0w0o", .driversLicense))
        #expect(!kept("request 7222-47b2-8dc5 ok", "7222-47b2-8dc5", .driversLicense))
        #expect(!kept("trace 0DE95A8B-6211-4679-9731-B17B420D8 done", "4679-9731", .phone))
        #expect(!kept("2026-10-04 12:30:45 [info] started", "2026-10-04", .phone))
        #expect(!kept("  1427\tlet x = 1\n  1428\tlet y = 2", "1427", .buildingNumber))
        #expect(!kept("sed -n 55,330p HTTPProxy.swift", "55,330p", .streetName))
        #expect(!kept("added 18 new keys to the catalog", "18 new keys", .streetName))
        #expect(!kept("build 4679 9731 passed", "4679 9731", .phone))
        #expect(!kept("token W3RD8G85BC rotated", "W3RD8G85BC", .driversLicense))
        #expect(!kept("Co-Authored-By: Claude <noreply@anthropic.com>", "noreply@anthropic.com", .email))
        #expect(!kept("Read FC debug output", "Read FC debug", .surname))
    }

    @Test("Real personal data still gets through the tightened rules")
    func truePositives() {
        #expect(kept("My passport number is X1234567.", "X1234567", .passport))
        #expect(kept("Driver's license: D1234567", "D1234567", .driversLicense))
        #expect(kept("IBAN DE89370400440532013000 please", "DE89370400440532013000", .bankAccount))
        #expect(kept("routing 021000021 acct", "021000021", .routingNumber))
        #expect(!kept("routing 021000022 acct", "021000022", .routingNumber))     // bad checksum
        #expect(kept("call me at +1 415 555 0142", "+1 415 555 0142", .phone))
        #expect(kept("reach her on 06 12 34 56 78", "06 12 34 56 78", .phone))
        #expect(kept("phone: 5550142999", "5550142999", .phone))
        #expect(kept("living at 1427 Juniper Hollow Road, Portland", "1427 Juniper Hollow Road", .streetName))
        #expect(kept("My customer is Margaret Holloway", "Margaret Holloway", .givenName))
    }

    @Test("Realistic agent traffic swaps nothing")
    func agentTrafficZeroSwaps() async throws {
        let toolOut = """
        commit 8ff43487a1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6
        Author: CI Bot <noreply@example.com>
        Date:   2026-10-04 12:30:45 +0200

            Fix session-scoped queues (#4679)

         Sources/AgentCoding/HTTPProxy.swift | 18 +++---
        session ec0b1592-369c-4f63-b5af-174c02268e1d resumed at 2026-10-04T14:07:53Z
          1427\tlet timeout = 30_000
          1428\treturn try await relay(id: "7481E5C0-1E90-48AB-AD4A-0CACE93E191B")
        build 4679-9731 took 3.2s; pid 72598; port 2331; sha256 b99s0mix6
        """
        let msgs: [[String: Any]] = [
            ["role": "system", "content": "You are Kimi, a coding agent. Session 0DE95A8B-6211-4509-875F-D9CB17B420D8."],
            ["role": "user", "content": "Show me the last commit and the log"],
            ["role": "assistant", "content": "", "tool_calls": [["id": "Shell:12", "type": "function",
                "function": ["name": "Shell", "arguments": #"{"command":"git log -1 --stat && tail -n 4 run.log"}"#]]]],
            ["role": "tool", "tool_call_id": "Shell:12", "content": toolOut],
        ]
        let tools: [[String: Any]] = [["type": "function", "function": ["name": "Shell",
            "description": "Run a command. Example id: 3F81AB1D, phone format 555-0100.",
            "parameters": ["type": "object", "properties": ["command": ["type": "string"]]]]]]
        let body = try JSONSerialization.data(withJSONObject: ["model": "kimi-for-coding", "messages": msgs, "tools": tools, "stream": true])
        let vault = PIIVault(secret: Data(repeating: 5, count: 32))
        let o = await PIIRewriter.rewriteRequest(body, policy: PIIPolicy(enabled: true), vault: vault)
        #expect(o.total == 0)
        #expect(o.body == body)
    }
}
