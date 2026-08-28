import Foundation
import Testing
@testable import bromure_ac

/// The wire↔OpenAI translations behind "point Local Models at your own
/// vLLM/Ollama": every guest wire (Anthropic messages / OpenAI chat / OpenAI
/// responses) must round-trip through the external server's chat API with
/// native tool calls intact — the repair pipeline downstream is a no-op when
/// a structured call is already present.
@Suite("ExternalEngine wire translation")
struct ExternalEngineTests {

    // MARK: - Request: Anthropic → chat

    @Test("Anthropic system + text messages become chat messages")
    func anthropicBasics() {
        let payload: [String: Any] = [
            "model": "qwen3:32b",
            "system": "be terse",
            "messages": [["role": "user", "content": "hi"]],
            "max_tokens": 512,
            "temperature": 0.2,
            "stop_sequences": ["END"],
        ]
        let out = ExternalEngine.chatRequest(from: payload, wire: .messages)
        #expect(out["model"] as? String == "qwen3:32b")
        #expect(out["stream"] as? Bool == false)
        #expect(out["max_tokens"] as? Int == 512)
        #expect((out["temperature"] as? NSNumber)?.doubleValue == 0.2)
        #expect(out["stop"] as? [String] == ["END"])
        let msgs = out["messages"] as? [[String: Any]] ?? []
        #expect(msgs.count == 2)
        #expect(msgs.first?["role"] as? String == "system")
        #expect(msgs.first?["content"] as? String == "be terse")
        #expect(msgs.last?["role"] as? String == "user")
        #expect(msgs.last?["content"] as? String == "hi")
    }

    @Test("Anthropic tool_use/tool_result history maps to native tool_calls + tool role")
    func anthropicToolHistory() {
        let payload: [String: Any] = [
            "model": "m",
            "messages": [
                ["role": "user", "content": "list files"],
                ["role": "assistant", "content": [
                    ["type": "text", "text": "on it"],
                    ["type": "tool_use", "id": "toolu_1", "name": "Bash",
                     "input": ["command": "ls"]],
                ]],
                ["role": "user", "content": [
                    ["type": "tool_result", "tool_use_id": "toolu_1", "content": "a.txt"],
                ]],
            ],
            "tools": [["name": "Bash", "description": "run",
                       "input_schema": ["type": "object"]]],
        ]
        let out = ExternalEngine.chatRequest(from: payload, wire: .messages)
        let msgs = out["messages"] as? [[String: Any]] ?? []
        #expect(msgs.count == 3)
        let assistant = msgs[1]
        #expect(assistant["role"] as? String == "assistant")
        #expect(assistant["content"] as? String == "on it")
        let calls = assistant["tool_calls"] as? [[String: Any]] ?? []
        #expect(calls.first?["id"] as? String == "toolu_1")
        let fn = calls.first?["function"] as? [String: Any]
        #expect(fn?["name"] as? String == "Bash")
        #expect((fn?["arguments"] as? String)?.contains("\"command\"") == true)
        let toolMsg = msgs[2]
        #expect(toolMsg["role"] as? String == "tool")
        #expect(toolMsg["tool_call_id"] as? String == "toolu_1")
        #expect(toolMsg["content"] as? String == "a.txt")
        let tools = out["tools"] as? [[String: Any]] ?? []
        #expect(tools.first?["type"] as? String == "function")
        #expect(((tools.first?["function"] as? [String: Any])?["name"] as? String) == "Bash")
    }

    @Test("Anthropic tool_choice maps: any→required, tool→function pin, string passes through")
    func anthropicToolChoice() {
        let any = ExternalEngine.chatRequest(
            from: ["model": "m", "messages": [], "tool_choice": ["type": "any"]], wire: .messages)
        #expect(any["tool_choice"] as? String == "required")
        let pinned = ExternalEngine.chatRequest(
            from: ["model": "m", "messages": [], "tool_choice": ["type": "tool", "name": "Bash"]],
            wire: .messages)
        let pin = pinned["tool_choice"] as? [String: Any]
        #expect(((pin?["function"] as? [String: Any])?["name"] as? String) == "Bash")
        // The stuck-preamble continuation sets the string form on every wire.
        let str = ExternalEngine.chatRequest(
            from: ["model": "m", "messages": [], "tool_choice": "required"], wire: .messages)
        #expect(str["tool_choice"] as? String == "required")
    }

    // MARK: - Request: Responses → chat

    @Test("Responses input items map to chat messages with native tool calls")
    func responsesRequest() {
        let payload: [String: Any] = [
            "model": "m",
            "instructions": "you are codex",
            "input": [
                ["type": "message", "role": "user",
                 "content": [["type": "input_text", "text": "build it"]]],
                ["type": "function_call", "call_id": "call_7", "name": "shell",
                 "arguments": "{\"cmd\":\"make\"}"],
                ["type": "function_call_output", "call_id": "call_7", "output": "ok"],
            ],
            "max_output_tokens": 900,
            "tools": [["type": "function", "name": "shell", "parameters": ["type": "object"]]],
        ]
        let out = ExternalEngine.chatRequest(from: payload, wire: .responses)
        #expect(out["max_tokens"] as? Int == 900)
        let msgs = out["messages"] as? [[String: Any]] ?? []
        #expect(msgs.count == 4)
        #expect(msgs[0]["role"] as? String == "system")
        #expect(msgs[1]["content"] as? String == "build it")
        let calls = msgs[2]["tool_calls"] as? [[String: Any]] ?? []
        #expect(calls.first?["id"] as? String == "call_7")
        #expect(msgs[3]["role"] as? String == "tool")
        #expect(msgs[3]["tool_call_id"] as? String == "call_7")
        let tools = out["tools"] as? [[String: Any]] ?? []
        #expect(((tools.first?["function"] as? [String: Any])?["name"] as? String) == "shell")
    }

    @Test("Chat requests pass through with streaming forced off")
    func chatPassthrough() {
        let payload: [String: Any] = ["model": "m", "stream": true,
                                      "messages": [["role": "user", "content": "hi"]],
                                      "frequency_penalty": 0.5]
        let out = ExternalEngine.chatRequest(from: payload, wire: .chat)
        #expect(out["stream"] as? Bool == false)
        #expect((out["frequency_penalty"] as? NSNumber)?.doubleValue == 0.5)
        #expect((out["messages"] as? [[String: Any]])?.count == 1)
    }

    // MARK: - Response: chat → Anthropic

    @Test("Chat text reply becomes an Anthropic message with usage + end_turn")
    func chatToMessages() {
        let chat: [String: Any] = [
            "model": "qwen3:32b",
            "choices": [["message": ["role": "assistant", "content": "done"],
                         "finish_reason": "stop"]],
            "usage": ["prompt_tokens": 10, "completion_tokens": 3],
        ]
        let msg = ExternalEngine.wireResponse(from: chat, wire: .messages)
        #expect(msg["type"] as? String == "message")
        #expect(msg["stop_reason"] as? String == "end_turn")
        let content = msg["content"] as? [[String: Any]] ?? []
        #expect(content.first?["text"] as? String == "done")
        let usage = msg["usage"] as? [String: Any]
        #expect(usage?["input_tokens"] as? Int == 10)
        #expect(usage?["output_tokens"] as? Int == 3)
    }

    @Test("Native tool_calls become tool_use blocks with parsed input")
    func chatToolCallsToMessages() {
        let chat: [String: Any] = [
            "model": "m",
            "choices": [["message": [
                "role": "assistant", "content": NSNull(),
                "tool_calls": [["id": "call_9", "type": "function",
                                "function": ["name": "Bash",
                                             "arguments": "{\"command\":\"ls\"}"]]],
            ], "finish_reason": "tool_calls"]],
        ]
        let msg = ExternalEngine.wireResponse(from: chat, wire: .messages)
        #expect(msg["stop_reason"] as? String == "tool_use")
        let content = msg["content"] as? [[String: Any]] ?? []
        let tu = content.first { ($0["type"] as? String) == "tool_use" }
        #expect(tu?["id"] as? String == "call_9")
        #expect(tu?["name"] as? String == "Bash")
        #expect((tu?["input"] as? [String: Any])?["command"] as? String == "ls")
        // Malformed arguments degrade to {} rather than dropping the call.
        let bad: [String: Any] = ["choices": [["message": [
            "tool_calls": [["id": "c", "function": ["name": "X", "arguments": "{oops"]]]]]]]
        let badMsg = ExternalEngine.wireResponse(from: bad, wire: .messages)
        let badTU = (badMsg["content"] as? [[String: Any]])?.first { ($0["type"] as? String) == "tool_use" }
        #expect((badTU?["input"] as? [String: Any])?.isEmpty == true)
    }

    @Test("length finish maps to max_tokens (messages) and incomplete (responses)")
    func lengthFinish() {
        let chat: [String: Any] = [
            "choices": [["message": ["content": "truncat"], "finish_reason": "length"]]]
        #expect(ExternalEngine.wireResponse(from: chat, wire: .messages)["stop_reason"] as? String == "max_tokens")
        #expect(ExternalEngine.wireResponse(from: chat, wire: .responses)["status"] as? String == "incomplete")
    }

    // MARK: - Response: chat → Responses

    @Test("Chat reply becomes Responses output items with function_call + usage total")
    func chatToResponses() {
        let chat: [String: Any] = [
            "model": "m",
            "choices": [["message": [
                "content": "running",
                "tool_calls": [["id": "call_3", "function": ["name": "shell",
                                                             "arguments": "{\"cmd\":\"ls\"}"]]],
            ], "finish_reason": "tool_calls"]],
            "usage": ["prompt_tokens": 7, "completion_tokens": 2],
        ]
        let resp = ExternalEngine.wireResponse(from: chat, wire: .responses)
        #expect(resp["status"] as? String == "completed")
        let output = resp["output"] as? [[String: Any]] ?? []
        #expect(output.count == 2)
        #expect(output.first?["type"] as? String == "message")
        let fc = output.last
        #expect(fc?["type"] as? String == "function_call")
        #expect(fc?["call_id"] as? String == "call_3")
        #expect(fc?["arguments"] as? String == "{\"cmd\":\"ls\"}")
        let usage = resp["usage"] as? [String: Any]
        #expect(usage?["total_tokens"] as? Int == 9)
    }

    @Test("Chat wire responses pass through untouched")
    func chatResponsePassthrough() {
        let chat: [String: Any] = ["id": "chatcmpl-1",
                                   "choices": [["message": ["content": "x"]]]]
        let out = ExternalEngine.wireResponse(from: chat, wire: .chat)
        #expect(out["id"] as? String == "chatcmpl-1")
    }

    // MARK: - Error bodies

    @Test("errorReason reads OpenAI/vLLM and Ollama error shapes")
    func errorShapes() {
        let openAI = try! JSONSerialization.data(
            withJSONObject: ["error": ["message": "model not found"]])
        #expect(ExternalEngine.errorReason(from: openAI) == "model not found")
        let ollama = try! JSONSerialization.data(withJSONObject: ["error": "pull it first"])
        #expect(ExternalEngine.errorReason(from: ollama) == "pull it first")
        #expect(ExternalEngine.errorReason(from: Data("plain text".utf8)) == "plain text")
    }

    // MARK: - Profile plumbing

    @Test("normalizedEngineBase defaults the scheme and strips /v1 + slashes")
    func urlNormalization() {
        #expect(Profile.normalizedEngineBase("192.168.1.20:8000")?.absoluteString == "http://192.168.1.20:8000")
        #expect(Profile.normalizedEngineBase("http://127.0.0.1:11434/v1/")?.absoluteString == "http://127.0.0.1:11434")
        #expect(Profile.normalizedEngineBase("https://llm.example.com/V1")?.absoluteString == "https://llm.example.com")
        #expect(Profile.normalizedEngineBase("   ") == nil)
        #expect(Profile.normalizedEngineBase(nil) == nil)
    }

    @Test("localEngineURL + key survive a Profile encode/decode round-trip")
    func profileRoundTrip() throws {
        var p = Profile(name: "ext-engine-test", tool: .claude, authMode: .token)
        p.modelRouting = .local
        p.activeModelID = "qwen3-coder:30b"
        p.localEngineURL = "http://127.0.0.1:11434"
        p.localEngineAPIKey = "sk-test"
        let data = try JSONEncoder().encode(p)
        let back = try JSONDecoder().decode(Profile.self, from: data)
        #expect(back.localEngineURL == "http://127.0.0.1:11434")
        #expect(back.localEngineAPIKey == "sk-test")
        #expect(back.localEngineBaseURL?.absoluteString == "http://127.0.0.1:11434")
        // Unset stays unset (and compact: the keys aren't emitted at all).
        let plain = Profile(name: "plain", tool: .claude, authMode: .token)
        let plainJSON = String(data: try JSONEncoder().encode(plain), encoding: .utf8) ?? ""
        #expect(!plainJSON.contains("localEngineURL"))
        let plainBack = try JSONDecoder().decode(Profile.self, from: JSONEncoder().encode(plain))
        #expect(plainBack.localEngineBaseURL == nil)
    }
}

/// End-to-end through the repair proxy: an Anthropic-wire request from a
/// "guest" (per-VM key + sentinel model) is translated to an OpenAI chat call
/// against a real loopback fake server, and its native tool_calls come back
/// as Anthropic tool_use SSE — the full external-engine path minus the VM.
@Suite("ExternalEngine through the repair proxy", .serialized)
struct ExternalEngineProxyTests {

    /// One-shot fake OpenAI server: accepts a single connection, captures the
    /// request, answers 200 with `responseJSON`, and exposes its bound port.
    private final class FakeOpenAIServer: @unchecked Sendable {
        let port: Int
        private let fd: Int32
        var capturedRequest: Data { box.captured }
        private let box = Box()

        /// The accept thread writes here; created before the thread starts so
        /// the closure never captures a half-initialized server.
        final class Box: @unchecked Sendable {
            var captured = Data()
            let done = DispatchSemaphore(value: 0)
        }

        convenience init?(responseJSON: [String: Any]) {
            self.init(rawBody: (try? JSONSerialization.data(withJSONObject: responseJSON)) ?? Data(),
                      contentType: "application/json")
        }

        /// `rawBody`/`contentType` verbatim — an SSE stream for the
        /// streaming-path tests.
        init?(rawBody: Data, contentType: String) {
            let sock = socket(AF_INET, SOCK_STREAM, 0)
            guard sock >= 0 else { return nil }
            var yes: Int32 = 1
            setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = 0
            _ = inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
            let bound = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0, listen(sock, 4) == 0 else { close(sock); return nil }
            var actual = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &actual) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(sock, $0, &len) }
            }
            fd = sock
            port = Int(UInt16(bigEndian: actual.sin_port))
            let listenFD = sock
            let box = box
            Thread.detachNewThread {
                let c = accept(listenFD, nil, nil)
                guard c >= 0 else { box.done.signal(); return }
                var buf = [UInt8](repeating: 0, count: 64 * 1024)
                var req = Data()
                while true {
                    if let headEnd = req.range(of: Data("\r\n\r\n".utf8)) {
                        let head = String(data: req.subdata(in: 0..<headEnd.lowerBound),
                                          encoding: .utf8) ?? ""
                        let cl = head.components(separatedBy: "\r\n")
                            .first { $0.lowercased().hasPrefix("content-length:") }
                            .flatMap { Int($0.split(separator: ":")[1]
                                .trimmingCharacters(in: .whitespaces)) } ?? 0
                        if req.count - headEnd.upperBound >= cl { break }
                    }
                    let n = read(c, &buf, buf.count)
                    if n <= 0 { break }
                    req.append(contentsOf: buf[0..<n])
                }
                box.captured = req
                let body = rawBody
                let head = "HTTP/1.1 200 OK\r\nContent-Type: \(contentType)\r\n"
                    + "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                var out = Data(head.utf8); out.append(body)
                out.withUnsafeBytes { raw in
                    var off = 0
                    while off < out.count {
                        let w = write(c, raw.baseAddress! + off, out.count - off)
                        if w <= 0 { break }
                        off += w
                    }
                }
                close(c)
                box.done.signal()
            }
        }
        func wait() { _ = box.done.wait(timeout: .now() + 10) }
        deinit { close(fd) }
    }

    @Test("Anthropic sentinel request → external chat call → tool_use SSE")
    func anthropicRoundTripThroughProxy() throws {
        let chatReply: [String: Any] = [
            "model": "qwen3:8b",
            "choices": [["message": [
                "role": "assistant", "content": "checking",
                "tool_calls": [["id": "call_42", "type": "function",
                                "function": ["name": "Bash",
                                             "arguments": "{\"command\":\"uname\"}"]]],
            ], "finish_reason": "tool_calls"]],
            "usage": ["prompt_tokens": 21, "completion_tokens": 5],
        ]
        let server = try #require(FakeOpenAIServer(responseJSON: chatReply))

        let pid = UUID()
        InferenceRepairProxy.shared.setExternalEngine(
            pid, ExternalEngine.Config(base: URL(string: "http://127.0.0.1:\(server.port)")!,
                                       apiKey: "sk-ext"))
        InferenceRepairProxy.shared.setActiveModel(pid, repo: "qwen3:8b")
        defer {
            InferenceRepairProxy.shared.setExternalEngine(pid, nil)
            InferenceRepairProxy.shared.clearActiveModel(pid)
        }

        let body: [String: Any] = [
            "model": InferenceService.localModelSentinel,
            "stream": true,
            "system": "be safe",
            "messages": [["role": "user", "content": "what os?"]],
            "tools": [["name": "Bash", "description": "run",
                       "input_schema": ["type": "object"]]],
            "max_tokens": 64,
        ]
        let req = InferenceRepairProxy.Request(
            method: "POST", path: "/v1/messages",
            headers: [("Authorization", "Bearer \(EngineKey.perVM(profileID: pid))"),
                      ("Content-Type", "application/json")],
            body: try JSONSerialization.data(withJSONObject: body))

        // enginePort 0: the built-in engine isn't running — the external
        // branch must never touch it.
        // No streamFD in tests → always the buffered path (never nil).
        let respBytes = InferenceRepairProxy.respond(to: req, enginePort: 0) ?? Data()
        server.wait()
        let resp = String(data: respBytes, encoding: .utf8) ?? ""

        // The reply is Anthropic SSE carrying the NATIVE tool call.
        #expect(resp.contains("HTTP/1.1 200"))
        #expect(resp.contains("event: message_start"))
        #expect(resp.contains("\"tool_use\""))
        #expect(resp.contains("\"call_42\""))
        #expect(resp.contains("\"Bash\""))
        #expect(resp.contains("\"tool_use\"") && resp.contains("uname"))

        // The external server saw an OpenAI chat call: right path, its own
        // bearer (not the guest's per-VM key), sentinel resolved, stream off.
        let seen = String(data: server.capturedRequest, encoding: .utf8) ?? ""
        #expect(seen.contains("POST /v1/chat/completions"))
        #expect(seen.contains("Bearer sk-ext"))
        #expect(!seen.contains(EngineKey.perVM(profileID: pid)))
        #expect(seen.contains("\"qwen3:8b\""))
        #expect(seen.contains("\"stream\":false"))
        #expect(seen.contains("\"role\":\"system\"") || seen.contains("be safe"))
    }
}

// MARK: - Streaming path

/// The streamed variant of the round trip: upstream replies with a chat SSE
/// stream; the proxy must relay live text deltas on the client socket, hold
/// back an end-of-text leaked tool call, and close the stream with the
/// rescued tool_use block. Uses a socketpair as the guest connection.
@Suite("ExternalEngine streaming through the repair proxy", .serialized)
struct ExternalEngineStreamingTests {

    private func sseBody(deltas: [String], finish: String) -> Data {
        var out = "data: {\"id\":\"c1\",\"model\":\"qwen3:8b\",\"created\":1,\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\"},\"finish_reason\":null}]}\n\n"
        for d in deltas {
            let obj: [String: Any] = ["choices": [["index": 0, "delta": ["content": d],
                                                   "finish_reason": NSNull()]]]
            let j = String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
            out += "data: \(j)\n\n"
        }
        out += "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"\(finish)\"}],\"usage\":{\"prompt_tokens\":9,\"completion_tokens\":7}}\n\n"
        out += "data: [DONE]\n\n"
        return Data(out.utf8)
    }

    @Test("Live deltas + end-of-text leak rescued into tool_use")
    func streamedLeakRescue() throws {
        // 400 chars of prose (released live), then a bare-JSON leaked call —
        // inside the emitter's holdback tail, so the guest must never see it.
        let prose = String(repeating: "Analyzing the build failure step by step. ", count: 10)
        let leak = "\n{\"name\": \"Bash\", \"arguments\": {\"command\": \"uname\"}}"
        let server = try #require(FakeSSEServerBox.make(
            body: sseBody(deltas: [prose, leak], finish: "stop")))

        let pid = UUID()
        InferenceRepairProxy.shared.setExternalEngine(
            pid, ExternalEngine.Config(base: URL(string: "http://127.0.0.1:\(server.port)")!,
                                       apiKey: "sk-ext"))
        InferenceRepairProxy.shared.setActiveModel(pid, repo: "qwen3:8b")
        defer {
            InferenceRepairProxy.shared.setExternalEngine(pid, nil)
            InferenceRepairProxy.shared.clearActiveModel(pid)
        }

        let body: [String: Any] = [
            "model": "qwen3:8b", "stream": true,
            "messages": [["role": "user", "content": "why does it fail?"]],
            "tools": [["name": "Bash", "description": "run",
                       "input_schema": ["type": "object"]]],
            "max_tokens": 512,
        ]
        let req = InferenceRepairProxy.Request(
            method: "POST", path: "/v1/messages",
            headers: [("Authorization", "Bearer \(EngineKey.perVM(profileID: pid))"),
                      ("Content-Type", "application/json")],
            body: try JSONSerialization.data(withJSONObject: body))

        var sp = [Int32](repeating: 0, count: 2)
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &sp) == 0)
        defer { close(sp[0]) }

        let resp = InferenceRepairProxy.respond(to: req, enginePort: 0, streamFD: sp[1])
        close(sp[1])
        #expect(resp == nil, "a streamed conversation returns nil (written to the fd)")

        var out = Data()
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(sp[0], &buf, buf.count)
            if n <= 0 { break }
            out.append(contentsOf: buf[0..<n])
        }
        let text = String(decoding: out, as: UTF8.self)

        #expect(text.contains("HTTP/1.1 200"))
        #expect(text.contains("event: message_start"))
        #expect(text.contains("text_delta"))
        #expect(text.contains("Analyzing the build failure"))
        // The leaked call was held back + rescued: never visible as text,
        // present as a native block.
        #expect(!text.contains("\\\"command\\\": \\\"uname\\\"")
                || text.contains("input_json_delta"))
        #expect(text.contains("\"tool_use\""))
        #expect(text.contains("\"Bash\""))
        #expect(text.contains("event: message_stop"))
        // stop_reason reflects the rescued call.
        #expect(text.contains("\"stop_reason\":\"tool_use\""))
    }
}

/// Vision: Anthropic image blocks (and screenshots inside tool_results)
/// must survive translation to OpenAI image_url parts, and omp's models.yml
/// must advertise image input for a vision-capable server model.
@Suite("Vision translation + capability flags")
struct VisionTranslationTests {

    @Test("Anthropic image block → image_url part (data: URI)")
    func imageBlockTranslates() {
        let payload: [String: Any] = [
            "model": "m",
            "messages": [["role": "user", "content": [
                ["type": "text", "text": "describe this"],
                ["type": "image", "source": ["type": "base64",
                                             "media_type": "image/png",
                                             "data": "AAAA"]],
            ]]],
            "max_tokens": 64,
        ]
        let chat = ExternalEngine.chatRequest(from: payload, wire: .messages)
        let msg = (chat["messages"] as? [[String: Any]])?.first
        let parts = msg?["content"] as? [[String: Any]]
        #expect(parts?.count == 2)
        #expect((parts?[0]["type"] as? String) == "text")
        let url = ((parts?[1]["image_url"] as? [String: Any])?["url"] as? String)
        #expect(url == "data:image/png;base64,AAAA")
    }

    @Test("Screenshot inside a tool_result lifts into the user turn")
    func toolResultImageLifts() {
        let payload: [String: Any] = [
            "model": "m",
            "messages": [["role": "user", "content": [
                ["type": "tool_result", "tool_use_id": "tu1", "content": [
                    ["type": "text", "text": "screenshot taken"],
                    ["type": "image", "source": ["type": "base64",
                                                 "media_type": "image/jpeg",
                                                 "data": "BBBB"]],
                ]],
            ]]],
            "max_tokens": 64,
        ]
        let chat = ExternalEngine.chatRequest(from: payload, wire: .messages)
        let msgs = chat["messages"] as? [[String: Any]] ?? []
        #expect(msgs.count == 2)
        #expect((msgs.first?["role"] as? String) == "tool")
        let parts = msgs.last?["content"] as? [[String: Any]]
        let url = ((parts?.last?["image_url"] as? [String: Any])?["url"] as? String)
        #expect(url == "data:image/jpeg;base64,BBBB")
    }

    @Test("omp models.yml advertises vision + reasoning when the server does")
    func ompCapabilityFlags() {
        let yaml = SessionDisk.ompModelsYAML(base: "https://bromure.llm/v1",
                                             model: "q", contextWindow: 262144,
                                             vision: true, reasoning: true)
        #expect(yaml.contains("input: [\"text\", \"image\"]"))
        #expect(yaml.contains("reasoning: true"))
        let plain = SessionDisk.ompModelsYAML(base: "b", model: "q")
        #expect(!plain.contains("input:") && !plain.contains("reasoning:"))
    }
}

/// Reasoning models: Ollama separates thinking into a `reasoning` field;
/// the proxy must stream it as a native thinking block BEFORE the text
/// block, so the agent can show/hide it on demand.
@Suite("Reasoning streaming through the repair proxy", .serialized)
struct ReasoningStreamingTests {

    @Test("reasoning deltas → thinking block, then text at the next index")
    func reasoningThenText() throws {
        var sse = "data: {\"id\":\"c1\",\"model\":\"m\",\"created\":1,\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\"},\"finish_reason\":null}]}\n\n"
        for frame in [["reasoning": "Let me think about tides. "],
                      ["reasoning": "The moon pulls the ocean."],
                      ["content": "Tides come from the moon's gravity acting on the ocean."]] {
            let obj: [String: Any] = ["choices": [["index": 0, "delta": frame,
                                                   "finish_reason": NSNull()]]]
            let j = String(data: try JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
            sse += "data: \(j)\n\n"
        }
        sse += "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
        let server = try #require(FakeSSEServerBox.make(body: Data(sse.utf8)))

        let pid = UUID()
        InferenceRepairProxy.shared.setExternalEngine(
            pid, ExternalEngine.Config(base: URL(string: "http://127.0.0.1:\(server.port)")!,
                                       apiKey: nil))
        defer { InferenceRepairProxy.shared.setExternalEngine(pid, nil) }

        let body: [String: Any] = [
            "model": "m", "stream": true,
            "messages": [["role": "user", "content": "why tides?"]],
            "max_tokens": 128,
        ]
        let req = InferenceRepairProxy.Request(
            method: "POST", path: "/v1/messages",
            headers: [("Authorization", "Bearer \(EngineKey.perVM(profileID: pid))")],
            body: try JSONSerialization.data(withJSONObject: body))

        var sp = [Int32](repeating: 0, count: 2)
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &sp) == 0)
        defer { close(sp[0]) }
        let resp = InferenceRepairProxy.respond(to: req, enginePort: 0, streamFD: sp[1])
        close(sp[1])
        #expect(resp == nil)

        var out = Data()
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(sp[0], &buf, buf.count)
            if n <= 0 { break }
            out.append(contentsOf: buf[0..<n])
        }
        let text = String(decoding: out, as: UTF8.self)

        #expect(text.contains("\"thinking\""))
        #expect(text.contains("thinking_delta"))
        #expect(text.contains("Let me think about tides"))
        // The thinking block (index 0) precedes the text block (index 1).
        let thinkStart = text.range(of: "\"thinking\"")
        let textDelta = text.range(of: "text_delta")
        #expect(thinkStart != nil && textDelta != nil
                && thinkStart!.lowerBound < textDelta!.lowerBound)
        #expect(text.contains("moon's gravity"))
        #expect(text.contains("event: message_stop"))
    }
}

/// Shim: reuse the private FakeOpenAIServer shape without widening its
/// access — a one-shot SSE server for the streaming tests.
private enum FakeSSEServerBox {
    final class Server: @unchecked Sendable {
        let port: Int
        private let fd: Int32
        init(fd: Int32, port: Int) { self.fd = fd; self.port = port }
        deinit { close(fd) }
    }

    static func make(body: Data) -> Server? {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return nil }
        var yes: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        _ = inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(sock, 4) == 0 else { close(sock); return nil }
        var actual = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(sock, $0, &len) }
        }
        let port = Int(UInt16(bigEndian: actual.sin_port))
        Thread.detachNewThread {
            let c = accept(sock, nil, nil)
            guard c >= 0 else { return }
            // Drain the request (best-effort: headers + body arrive fast).
            var buf = [UInt8](repeating: 0, count: 64 * 1024)
            _ = read(c, &buf, buf.count)
            let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n"
                + "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            var out = Data(head.utf8); out.append(body)
            out.withUnsafeBytes { raw in
                var off = 0
                while off < out.count {
                    let w = write(c, raw.baseAddress! + off, out.count - off)
                    if w <= 0 { break }
                    off += w
                }
            }
            close(c)
        }
        return Server(fd: sock, port: port)
    }
}

/// Built-in-engine streaming: a fake engine speaks the proxy-internal
/// protocol ({"d":…} deltas + a {"final":…} native message); the proxy (no
/// external engine registered) must relay live deltas and close with the
/// final message's blocks — no wire translation anywhere.
@Suite("Built-in MLX streaming through the repair proxy", .serialized)
struct BuiltinStreamingTests {

    @Test("Deltas relay live; the final native message closes the stream")
    func builtinStreamRoundTrip() throws {
        let prose = String(repeating: "Reading the failing test to see what it expects. ", count: 9)
        let finalMessage: [String: Any] = [
            "id": "msg_native1", "type": "message", "role": "assistant",
            "model": "mlx-community/qwen-7b",
            "content": [["type": "text", "text": prose.trimmingCharacters(in: .whitespaces)],
                        ["type": "tool_use", "id": "tu_9", "name": "Read",
                         "input": ["file_path": "/x/test.py"]]],
            "stop_reason": "tool_use",
            "usage": ["input_tokens": 33, "output_tokens": 44],
        ]
        var sse = ""
        // Two delta frames splitting the prose, like the engine's DeltaRelay.
        let mid = prose.index(prose.startIndex, offsetBy: prose.count / 2)
        for chunk in [String(prose[..<mid]), String(prose[mid...])] {
            let f = try JSONSerialization.data(withJSONObject: ["d": chunk])
            sse += "data: \(String(data: f, encoding: .utf8)!)\n\n"
        }
        let ff = try JSONSerialization.data(withJSONObject: ["final": finalMessage])
        sse += "data: \(String(data: ff, encoding: .utf8)!)\n\ndata: [DONE]\n\n"
        let engine = try #require(FakeSSEServerBox.make(body: Data(sse.utf8)))

        let pid = UUID()   // NO external engine registered → built-in path
        let body: [String: Any] = [
            "model": "mlx-community/qwen-7b", "stream": true,
            "messages": [["role": "user", "content": "why does the test fail?"]],
            "tools": [["name": "Read", "description": "read",
                       "input_schema": ["type": "object"]]],
            "max_tokens": 512,
        ]
        let req = InferenceRepairProxy.Request(
            method: "POST", path: "/v1/messages",
            headers: [("Authorization", "Bearer \(EngineKey.perVM(profileID: pid))"),
                      ("Content-Type", "application/json")],
            body: try JSONSerialization.data(withJSONObject: body))

        var sp = [Int32](repeating: 0, count: 2)
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &sp) == 0)
        defer { close(sp[0]) }

        let resp = InferenceRepairProxy.respond(to: req, enginePort: engine.port,
                                                streamFD: sp[1])
        close(sp[1])
        #expect(resp == nil, "a streamed conversation returns nil (written to the fd)")

        var out = Data()
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(sp[0], &buf, buf.count)
            if n <= 0 { break }
            out.append(contentsOf: buf[0..<n])
        }
        let text = String(decoding: out, as: UTF8.self)

        #expect(text.contains("HTTP/1.1 200"))
        #expect(text.contains("event: message_start"))
        #expect(text.contains("text_delta"))
        #expect(text.contains("Reading the failing test"))
        #expect(text.contains("\"tool_use\""))
        #expect(text.contains("\"Read\""))
        #expect(text.contains("\"stop_reason\":\"tool_use\""))
        #expect(text.contains("event: message_stop"))
    }
}
