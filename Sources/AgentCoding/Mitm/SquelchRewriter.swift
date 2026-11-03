import CryptoKit
import Foundation

/// Applies `Squelch` to an AI request: finds the shell command each tool
/// result answers, trims that result, and rewrites the request in place —
/// only the trimmed strings are re-encoded, every other byte goes out as the
/// agent sent it (as `PIIRewriter` does), so signed thinking blocks and the
/// prompt-cache prefix are untouched.
///
/// Wire shapes:
/// - Anthropic Messages (Claude Code, omp, Kimi's Anthropic endpoint):
///   `tool_use {id, name, input.command}` → `tool_result {tool_use_id, content}`.
/// - OpenAI Chat Completions (Kimi, Grok, custom engines):
///   `assistant.tool_calls[] {id, function {name, arguments}}` → `tool {tool_call_id, content}`.
/// - OpenAI Responses (Codex, over HTTP or its WebSocket):
///   `function_call {call_id, name, arguments}` / `local_shell_call` →
///   `function_call_output` / `local_shell_call_output {call_id, output}`.
/// A result whose call isn't in the request (a Responses turn chained by
/// `previous_response_id`, Codex's WebSocket) is matched with the call the
/// model's reply announced (`SquelchCallRegistry`); one whose call was never
/// seen is left alone — its text alone can't say it wasn't a `cat` of a log.
enum SquelchRewriter {
    /// One trimmed tool result.
    struct Trim: Equatable {
        var callID: String
        var command: String
        var family: Squelch.Family
        var rawBytes: Int
        var keptBytes: Int
    }

    struct Outcome {
        var body: Data
        var trims: [Trim] = []
        /// Command outputs looked at (trimmed or not), by call id → raw size:
        /// what the savings are a share of.
        var seen: [String: Int] = [:]
        /// The conversation the body names (`metadata.user_id`,
        /// `prompt_cache_key`), read while it was parsed anyway.
        var conversation: String?
    }

    /// Tool names that run a shell command, across the agents.
    static func isCommandTool(_ name: String) -> Bool {
        switch name.lowercased() {
        case "bash", "shell", "exec_command", "shell_command", "local_shell", "run_command", "runcommand",
             "run_terminal_command", "run_terminal_cmd", "execute", "execute_command", "exec", "terminal",
             "run", "container.exec", "run_shell_command", "shell_exec":
            return true
        default:
            return false
        }
    }

    /// The command line in a tool call's input.
    static func command(fromInput input: Any?) -> String? {
        var dict = input as? [String: Any]
        if dict == nil, let s = input as? String, let d = s.data(using: .utf8) {
            dict = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
        }
        guard let dict else { return nil }
        for key in ["command", "cmd", "script", "commandLine"] {
            if let s = dict[key] as? String, !s.isEmpty { return s }
            if let a = dict[key] as? [Any] {
                let argv = a.compactMap { $0 as? String }
                if argv.count >= 3, ["bash", "sh", "zsh", "/bin/bash", "/bin/sh", "/bin/zsh"].contains(argv[0]),
                   argv[1].hasPrefix("-"), argv[1].contains("c") {
                    return argv[2...].joined(separator: " ")
                }
                if !argv.isEmpty { return argv.joined(separator: " ") }
            }
        }
        return nil
    }

    /// Cheap probe before any parsing: a request that carries tool output.
    static func mayCarryToolOutput(_ body: Data) -> Bool {
        for k in ["\"tool_result\"", "\"tool_call_id\"", "\"function_call_output\"", "\"local_shell_call_output\"",
                  "\"custom_tool_call_output\"", "\"shell_call_output\""] where body.range(of: Data(k.utf8)) != nil {
            return true
        }
        return false
    }

    /// `priorCall`: a call made in an earlier turn, by id (`SquelchCallRegistry`).
    static func rewrite(_ body: Data,
                        priorCall: (String) -> (name: String, command: String?)? = { _ in nil }) -> Outcome {
        var outcome = Outcome(body: body)
        guard mayCarryToolOutput(body),
              let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return outcome }
        outcome.conversation = sessionKey(root: root)

        // Every call's name and command, wherever it sits in the request.
        var calls: [String: (name: String, command: String?)] = [:]
        // The result strings to consider: their path in the body and the call they answer.
        var targets: [(path: [JSONPath.Elem], callID: String, wrapped: Bool)] = []

        if let messages = root["messages"] as? [Any] {
            for (mi, m) in messages.enumerated() {
                guard let msg = m as? [String: Any] else { continue }
                // Anthropic content blocks.
                if let blocks = msg["content"] as? [Any] {
                    for (bi, b) in blocks.enumerated() {
                        guard let block = b as? [String: Any], let type = block["type"] as? String else { continue }
                        if type == "tool_use" || type == "server_tool_use", let id = block["id"] as? String {
                            calls[id] = (block["name"] as? String ?? "", command(fromInput: block["input"]))
                        } else if type == "tool_result", let id = block["tool_use_id"] as? String {
                            let base: [JSONPath.Elem] = [.key("messages"), .index(mi), .key("content"), .index(bi), .key("content")]
                            if block["content"] is String {
                                targets.append((base, id, false))
                            } else if let parts = block["content"] as? [Any] {
                                for (pi, p) in parts.enumerated() {
                                    if let part = p as? [String: Any], part["type"] as? String == "text", part["text"] is String {
                                        targets.append((base + [.index(pi), .key("text")], id, false))
                                    }
                                }
                            }
                        }
                    }
                }
                // OpenAI chat completions.
                if let toolCalls = msg["tool_calls"] as? [Any] {
                    for c in toolCalls {
                        guard let call = c as? [String: Any], let id = call["id"] as? String,
                              let fn = call["function"] as? [String: Any] else { continue }
                        calls[id] = (fn["name"] as? String ?? "", command(fromInput: fn["arguments"]))
                    }
                }
                if msg["role"] as? String == "tool", let id = msg["tool_call_id"] as? String {
                    let base: [JSONPath.Elem] = [.key("messages"), .index(mi), .key("content")]
                    if msg["content"] is String {
                        targets.append((base, id, false))
                    } else if let parts = msg["content"] as? [Any] {
                        for (pi, p) in parts.enumerated() {
                            if let part = p as? [String: Any], part["text"] is String {
                                targets.append((base + [.index(pi), .key("text")], id, false))
                            }
                        }
                    }
                }
            }
        }

        // OpenAI Responses: the turn's `input`, or a realtime
        // `conversation.item.create`'s one `item` (Codex's WebSocket).
        var items: [(base: [JSONPath.Elem], item: Any)] = []
        if let input = root["input"] as? [Any] {
            items = input.enumerated().map { ([.key("input"), .index($0.offset)], $0.element) }
        } else if let item = root["item"] {
            items = [([.key("item")], item)]
        }
        do {
            for (itemPath, it) in items {
                guard let item = it as? [String: Any], let type = item["type"] as? String,
                      let id = item["call_id"] as? String else { continue }
                switch type {
                case "function_call":
                    calls[id] = (item["name"] as? String ?? "", command(fromInput: item["arguments"]))
                case "local_shell_call", "shell_call":
                    calls[id] = ("local_shell", command(fromInput: item["action"]))
                case "custom_tool_call":
                    calls[id] = (item["name"] as? String ?? "", command(fromInput: item["input"]))
                case "function_call_output", "local_shell_call_output", "shell_call_output", "custom_tool_call_output":
                    let base: [JSONPath.Elem] = itemPath + [.key("output")]
                    if item["output"] is String {
                        targets.append((base, id, true))
                    } else if let parts = item["output"] as? [Any] {
                        for (pi, p) in parts.enumerated() {
                            if let part = p as? [String: Any], part["text"] is String {
                                targets.append((base + [.index(pi), .key("text")], id, true))
                            }
                        }
                    }
                default:
                    break
                }
            }
        }
        guard !targets.isEmpty else { return outcome }

        var replacements: [[JSONPath.Elem]: String] = [:]
        var trimsByCall: [String: Trim] = [:]
        for t in targets {
            // Only a shell call's result, and only when its command line is
            // known — from this request or an earlier reply. A call whose
            // input isn't a command (Codex code mode's `exec` takes a script)
            // is left alone: its output's text can't say what printed it.
            guard let call = calls[t.callID] ?? priorCall(t.callID), isCommandTool(call.name),
                  let command = call.command else { continue }
            guard let text = JSONPath.value(at: t.path, in: root) as? String else { continue }
            outcome.seen[t.callID, default: 0] += text.utf8.count
            guard let r = trimResult(text, command: command, unwrapCodex: t.wrapped) else { continue }
            replacements[t.path] = r.text
            var trim = trimsByCall[t.callID] ?? Trim(callID: t.callID, command: command, family: r.family,
                                                     rawBytes: 0, keptBytes: 0)
            trim.rawBytes += r.rawBytes
            trim.keptBytes += r.keptBytes
            trimsByCall[t.callID] = trim
        }
        guard !replacements.isEmpty,
              let refs = JSONPath.strings([UInt8](body)) else { return outcome }
        var bytes = [UInt8](body)
        // Back to front, so earlier ranges stay valid.
        for ref in refs.reversed() {
            guard let new = replacements[ref.path] else { continue }
            bytes.replaceSubrange(ref.range, with: JSONStrings.encode(new))
        }
        outcome.body = Data(bytes)
        outcome.trims = trimsByCall.values.sorted { $0.callID < $1.callID }
        return outcome
    }

    /// A tool result as the model should read it. Codex wraps a command's
    /// output: `exec_command` in a header ending `Output:`, the older `shell`
    /// tool in a JSON document whose `output` is the text — only the text
    /// itself is trimmed.
    typealias Trimmed = (text: String, family: Squelch.Family, rawBytes: Int, keptBytes: Int)

    /// Every turn resends the whole conversation: each output is trimmed
    /// once, then read back from here.
    private static let cache = TrimCache()

    static func trimResult(_ text: String, command: String, unwrapCodex: Bool) -> Trimmed? {
        let key = TrimCache.key(text, command: command, unwrapCodex: unwrapCodex)
        if let hit = cache.get(key) { return hit }
        let r = computeTrim(text, command: command, unwrapCodex: unwrapCodex)
        cache.put(key, r)
        return r
    }

    private static func computeTrim(_ text: String, command: String, unwrapCodex: Bool) -> Trimmed? {
        if unwrapCodex, text.hasPrefix("{"), let d = text.data(using: .utf8),
           let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
           let inner = obj["output"] as? String,
           let r = Squelch.trim(command: command, output: inner),
           let refs = JSONPath.strings([UInt8](d)),
           let ref = refs.first(where: { $0.path == [.key("output")] }) {
            var bytes = [UInt8](d)
            bytes.replaceSubrange(ref.range, with: JSONStrings.encode(r.text))
            let out = String(decoding: bytes, as: UTF8.self)
            return (out, r.family, text.utf8.count, out.utf8.count)
        }
        if unwrapCodex, let marker = text.range(of: "\nOutput:\n"),
           text.distance(from: text.startIndex, to: marker.lowerBound) < 600,
           text.hasPrefix("Chunk ID:") || text.hasPrefix("Wall time:") || text.hasPrefix("Exit code:")
            || text[..<marker.lowerBound].contains("Process exited with code") {
            let head = String(text[..<marker.upperBound])
            guard let r = Squelch.trim(command: command, output: String(text[marker.upperBound...])) else { return nil }
            let out = head + r.text
            return (out, r.family, text.utf8.count, out.utf8.count)
        }
        guard let r = Squelch.trim(command: command, output: text) else { return nil }
        return (r.text, r.family, r.rawBytes, r.keptBytes)
    }

    /// Which of the agent's conversations a request belongs to, when it says:
    /// Claude Code's session id (a header, or `metadata.user_id`), Codex's
    /// conversation id (`session_id` / `conversation_id` headers,
    /// `prompt_cache_key`). It's the agent's own id — the one a Bromure
    /// session keeps as `agentTranscriptID` — so savings land on the session.
    static func sessionKey(headers: String, body: Data) -> String? {
        if let k = sessionKey(headers: headers) { return k }
        guard body.count < 64 << 20,
              let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return nil }
        return sessionKey(root: root)
    }

    static func sessionKey(headers: String) -> String? {
        for name in ["x-claude-code-session-id", "session_id", "session-id", "conversation_id", "x-session-id"] {
            if let v = headerValue(name, in: headers), isID(v) { return v.lowercased() }
        }
        return nil
    }

    static func sessionKey(root: [String: Any]) -> String? {
        if let meta = root["metadata"] as? [String: Any], let uid = meta["user_id"] as? String {
            if let d = uid.data(using: .utf8), let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
               let s = j["session_id"] as? String, isID(s) { return s.lowercased() }
            if let r = uid.range(of: "_session_") {
                let s = String(uid[r.upperBound...])
                if isID(s) { return s.lowercased() }
            }
        }
        if let k = root["prompt_cache_key"] as? String, isID(k) { return k.lowercased() }
        return nil
    }

    static func isID(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.count >= 8 && t.count <= 80 && t.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    private static func headerValue(_ name: String, in head: String) -> String? {
        for line in head.split(separator: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            if line[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == name {
                return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}

/// Calls the model announced in its replies, by id: what a later request
/// that carries only the result (a chained Responses turn) is matched with.
/// Per workspace, the most recent few thousand.
final class SquelchCallRegistry: @unchecked Sendable {
    static let shared = SquelchCallRegistry()

    private let lock = NSLock()
    private var calls: [String: (name: String, command: String?)] = [:]
    private var order: [String] = []
    private let limit = 4000

    func learn(_ profileID: UUID, callID: String, name: String, command: String?) {
        let key = profileID.uuidString + "|" + callID
        lock.lock(); defer { lock.unlock() }
        if calls.updateValue((name, command), forKey: key) == nil { order.append(key) }
        if order.count > limit {
            let drop = order.count - limit
            for k in order.prefix(drop) { calls[k] = nil }
            order.removeFirst(drop)
        }
    }

    func call(_ profileID: UUID, _ callID: String) -> (name: String, command: String?)? {
        lock.lock(); defer { lock.unlock() }
        return calls[profileID.uuidString + "|" + callID]
    }

    /// The calls in a Responses server event — an `output_item.done`, or a
    /// `response.completed` carrying the whole output.
    func learn(fromServerEvent payload: Data, profileID: UUID) {
        guard payload.range(of: Data("\"call_id\"".utf8)) != nil,
              let obj = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] else { return }
        var items: [Any] = []
        if let item = obj["item"] { items.append(item) }
        if let output = (obj["response"] as? [String: Any])?["output"] as? [Any] { items += output }
        for case let item as [String: Any] in items {
            guard let id = item["call_id"] as? String, let type = item["type"] as? String else { continue }
            switch type {
            case "function_call":
                learn(profileID, callID: id, name: item["name"] as? String ?? "",
                      command: SquelchRewriter.command(fromInput: item["arguments"]))
            case "local_shell_call", "shell_call":
                learn(profileID, callID: id, name: "local_shell", command: SquelchRewriter.command(fromInput: item["action"]))
            case "custom_tool_call":
                learn(profileID, callID: id, name: item["name"] as? String ?? "",
                      command: SquelchRewriter.command(fromInput: item["input"]))
            default:
                break
            }
        }
    }
}

/// Every string value in a JSON document with its full path — for rewriting
/// chosen values without re-serializing the rest (see `JSONStrings`).
enum JSONPath {
    enum Elem: Hashable { case key(String), index(Int) }

    struct Ref {
        /// Byte range including the quotes.
        let range: Range<Int>
        let path: [Elem]
    }

    static func value(at path: [Elem], in root: Any) -> Any? {
        var cur: Any? = root
        for e in path {
            switch e {
            case .key(let k): cur = (cur as? [String: Any])?[k]
            case .index(let i):
                guard let a = cur as? [Any], a.indices.contains(i) else { return nil }
                cur = a[i]
            }
        }
        return cur
    }

    static func strings(_ b: [UInt8]) -> [Ref]? {
        // Each open container: its path, and (objects) the pending key or
        // (arrays) the index of the next element.
        enum Frame { case object(key: String?), array(next: Int) }
        var stack: [Frame] = []
        var path: [Elem] = []
        var refs: [Ref] = []
        var i = 0
        let n = b.count

        /// The path a value starting now sits at.
        func valuePath() -> [Elem] {
            switch stack.last {
            case .object(let k)?: return path + [.key(k ?? "")]
            case .array(let next)?: return path + [.index(next)]
            case nil: return path
            }
        }
        func enter(_ f: Frame) {
            path = valuePath()
            stack.append(f)
        }
        /// After a value completes at this level.
        func advance() {
            switch stack.last {
            case .object?: stack[stack.count - 1] = .object(key: nil)
            case .array(let next)?: stack[stack.count - 1] = .array(next: next + 1)
            case nil: break
            }
        }

        while i < n {
            let c = b[i]
            switch c {
            case UInt8(ascii: "{"):
                enter(.object(key: nil)); i += 1
            case UInt8(ascii: "["):
                enter(.array(next: 0)); i += 1
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                guard !stack.isEmpty else { return nil }
                stack.removeLast()
                if !path.isEmpty { path.removeLast() }
                advance(); i += 1
            case UInt8(ascii: "\""):
                let start = i
                i += 1
                while i < n && b[i] != UInt8(ascii: "\"") { i += b[i] == UInt8(ascii: "\\") ? 2 : 1 }
                guard i < n else { return nil }
                i += 1
                if case .object(nil)? = stack.last, isKeyPosition(b, after: i) {
                    stack[stack.count - 1] = .object(key: JSONStrings.decode(b, start..<i))
                } else {
                    refs.append(Ref(range: start..<i, path: valuePath()))
                    advance()
                }
            case UInt8(ascii: ","), UInt8(ascii: ":"), 0x20, 0x09, 0x0A, 0x0D:
                i += 1
            default:
                // A number, true, false or null.
                while i < n, !",}] \t\r\n".utf8.contains(b[i]) { i += 1 }
                advance()
            }
        }
        return stack.isEmpty ? refs : nil
    }

    /// A string followed by `:` is a key.
    private static func isKeyPosition(_ b: [UInt8], after i: Int) -> Bool {
        var j = i
        while j < b.count, b[j] == 0x20 || b[j] == 0x09 || b[j] == 0x0A || b[j] == 0x0D { j += 1 }
        return j < b.count && b[j] == UInt8(ascii: ":")
    }
}

/// Trim results by output (a digest of the command and the text), the
/// most recent few thousand.
final class TrimCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: SquelchRewriter.Trimmed?] = [:]
    private var order: [String] = []
    private let limit: Int

    init(limit: Int = 4000) { self.limit = limit }

    static func key(_ text: String, command: String, unwrapCodex: Bool) -> String {
        var h = SHA256()
        h.update(data: Data(command.utf8))
        h.update(data: Data([0, unwrapCodex ? 1 : 0]))
        h.update(data: Data(text.utf8))
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// nil: not cached; .some(nil): cached as "leave it alone".
    func get(_ key: String) -> SquelchRewriter.Trimmed?? {
        lock.lock(); defer { lock.unlock() }
        return entries[key]
    }

    func put(_ key: String, _ value: SquelchRewriter.Trimmed?) {
        lock.lock(); defer { lock.unlock() }
        if entries.updateValue(value, forKey: key) == nil { order.append(key) }
        if order.count > limit {
            let drop = order.count - limit
            for k in order.prefix(drop) { entries[k] = nil }
            order.removeFirst(drop)
        }
    }
}
