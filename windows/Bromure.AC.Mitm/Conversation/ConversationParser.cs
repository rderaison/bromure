// macos-source: Sources/AgentCoding/ConversationView.swift @ 18a8f5638b0f
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Bromure.AC.Mitm.Conversation;

/// <summary>
/// Best-effort parser for one LLM exchange. Returns null when the
/// host/body combination doesn't match any provider — caller falls
/// back to the raw view.
///
/// <para>This is the slim Windows port. Covers the workhorse paths:
/// Anthropic Messages API (full + SSE) and OpenAI Chat Completions
/// (full + SSE). OpenAI Responses, Gemini, Cohere, and the WebSocket
/// transcript walker are deferred follow-ups — anchored to the same
/// Swift source so the parity check surfaces drift in either tree.</para>
/// </summary>
public static class ConversationParser
{
    /// <summary>Parse a request/response pair captured by the proxy.
    /// Either side may be empty (request lost or response truncated)
    /// — the parser still tries the other side.</summary>
    public static Conversation? Parse(string host, byte[]? requestBody, byte[]? responseBody)
    {
        // The proxy hands us full HTTP wire frames (request line +
        // headers + body). Strip the framing so the JSON parsers see
        // only the body.
        var req = StripHttpFraming(requestBody);
        var res = StripHttpFraming(responseBody);

        // WebSocket transcript? Walk it chronologically so user turns
        // and assistant turns interleave correctly, even when the
        // session compacts history. The synthesize-and-route fallback
        // can't recover that ordering because it merges all SSE
        // events into one assistant message.
        if (ParseWebSocketTranscript(host, res) is { } wsConvo) return wsConvo;

        var h = host.ToLowerInvariant();
        if (h.Contains("anthropic.com")) return ParseAnthropic(req, res);
        if (h.Contains("openai.com") || h.Contains("mistral.ai")
            || h.Contains("x.ai") || h.Contains("groq.com")
            || h.Contains("perplexity.ai"))
        {
            return ParseOpenAi(req, res);
        }
        if (h.Contains("googleapis.com") || h.Contains("google.com"))
            return ParseGemini(req, res);
        if (h.Contains("cohere.com")) return ParseCohere(req, res);
        return null;
    }

    /// <summary>
    /// Anthropic /v1/messages parser — JSON request, JSON or SSE
    /// response. Returns null when neither side carries a usable
    /// message list.
    /// </summary>
    private static Conversation? ParseAnthropic(byte[]? req, byte[]? res)
    {
        var convo = new Conversation { Provider = Provider.Anthropic };

        if (req is { Length: > 0 } && TryParseJsonObject(req, out var reqJson))
        {
            convo.Model = reqJson["model"]?.GetValue<string>();
            // System prompt: string or array of {text:...} blocks.
            if (reqJson["system"] is JsonValue sysVal && sysVal.TryGetValue<string>(out var sysStr))
            {
                convo.SystemPrompt = sysStr;
            }
            else if (reqJson["system"] is JsonArray sysArr)
            {
                var texts = sysArr.OfType<JsonObject>()
                    .Select(o => o["text"]?.GetValue<string>())
                    .Where(t => !string.IsNullOrEmpty(t))
                    .ToList();
                if (texts.Count > 0) convo.SystemPrompt = string.Join("\n\n", texts);
            }
            if (reqJson["messages"] is JsonArray msgs)
            {
                foreach (var m in msgs.OfType<JsonObject>())
                {
                    var role = m["role"]?.GetValue<string>();
                    if (!TryParseRole(role, out var r)) continue;
                    var blocks = AnthropicBlocks(m["content"]);
                    convo.Messages.Add(new Message(r, blocks));
                }
            }
        }

        if (res is { Length: > 0 })
        {
            // Two shapes: full JSON or SSE chunks.
            if (TryParseJsonObject(res, out var resJson))
            {
                if (resJson["content"] is JsonArray blockArr)
                {
                    var blocks = blockArr.OfType<JsonObject>()
                        .Select(AnthropicBlock).OfType<Block>().ToList();
                    if (blocks.Count > 0) convo.Messages.Add(new Message(Role.Assistant, blocks));
                }
                if (resJson["usage"] is JsonObject usage)
                {
                    if (usage["input_tokens"] is JsonValue iv && iv.TryGetValue<int>(out var it))
                        convo.InputTokens = it;
                    if (usage["output_tokens"] is JsonValue ov && ov.TryGetValue<int>(out var ot))
                        convo.OutputTokens = ot;
                }
            }
            else
            {
                var sseText = Encoding.UTF8.GetString(res);
                var assistant = ParseAnthropicSse(sseText);
                if (assistant.Content.Count > 0) convo.Messages.Add(assistant);
            }
        }

        return convo.Messages.Count == 0 ? null : convo;
    }

    private static IEnumerable<Block> AnthropicBlocks(JsonNode? content)
    {
        if (content is JsonValue v && v.TryGetValue<string>(out var s))
            return new[] { (Block)new Block.Text(s) };
        if (content is JsonArray arr)
        {
            return arr.OfType<JsonObject>()
                .Select(AnthropicBlock).OfType<Block>().ToArray();
        }
        return Array.Empty<Block>();
    }

    private static Block? AnthropicBlock(JsonObject b)
    {
        var type = b["type"]?.GetValue<string>();
        if (type is null) return null;
        switch (type)
        {
            case "text":
                return new Block.Text(b["text"]?.GetValue<string>() ?? "");
            case "tool_use":
                {
                    var name = b["name"]?.GetValue<string>() ?? "tool";
                    var inputObj = b["input"] as JsonObject;
                    var input = inputObj is null ? "" : inputObj.ToJsonString(
                        new JsonSerializerOptions { WriteIndented = true });
                    return new Block.ToolUse(name, input);
                }
            case "tool_result":
                {
                    var id = b["tool_use_id"]?.GetValue<string>();
                    var isError = b["is_error"] is JsonValue ev && ev.TryGetValue<bool>(out var e) && e;
                    string text = "";
                    if (b["content"] is JsonValue cv && cv.TryGetValue<string>(out var cs)) text = cs;
                    else if (b["content"] is JsonArray ca)
                    {
                        text = string.Join("\n", ca.OfType<JsonObject>()
                            .Select(o => o["text"]?.GetValue<string>())
                            .Where(t => !string.IsNullOrEmpty(t))!);
                    }
                    return new Block.ToolResult(id, text, isError);
                }
            case "image":
                {
                    var mediaType = (b["source"] as JsonObject)?["media_type"]?.GetValue<string>() ?? "image";
                    return new Block.Image(mediaType);
                }
            default:
                return null;
        }
    }

    /// <summary>
    /// Walk an Anthropic SSE stream, accumulate deltas keyed by
    /// content_block index, return the assembled assistant message.
    /// Supports text + tool_use blocks (the latter merge
    /// <c>partial_json</c> into a single JSON string).
    /// </summary>
    private static Message ParseAnthropicSse(string text)
    {
        var blocks = new SortedDictionary<int, AnthropicAccum>();
        foreach (var chunk in text.Split("\n\n"))
        {
            var dataLine = chunk.Split('\n')
                .FirstOrDefault(l => l.StartsWith("data:", StringComparison.Ordinal));
            if (dataLine is null) continue;
            var data = dataLine["data:".Length..].Trim();
            if (data.Length == 0) continue;
            JsonObject? obj;
            try { obj = JsonNode.Parse(data) as JsonObject; }
            catch (JsonException) { continue; }
            if (obj is null) continue;
            var type = obj["type"]?.GetValue<string>();
            if (type is null) continue;
            switch (type)
            {
                case "content_block_start":
                    {
                        if (obj["index"] is not JsonValue iv || !iv.TryGetValue<int>(out var idx)) break;
                        if (obj["content_block"] is not JsonObject blk) break;
                        if (!blocks.TryGetValue(idx, out var a)) a = new AnthropicAccum();
                        a.Type = blk["type"]?.GetValue<string>() ?? "text";
                        if (a.Type == "tool_use") a.ToolName = blk["name"]?.GetValue<string>() ?? "tool";
                        blocks[idx] = a;
                        break;
                    }
                case "content_block_delta":
                    {
                        if (obj["index"] is not JsonValue iv || !iv.TryGetValue<int>(out var idx)) break;
                        if (obj["delta"] is not JsonObject delta) break;
                        if (!blocks.TryGetValue(idx, out var a)) a = new AnthropicAccum();
                        if (delta["text"] is JsonValue tv && tv.TryGetValue<string>(out var t))
                            a.Text.Append(t);
                        if (delta["partial_json"] is JsonValue pv && pv.TryGetValue<string>(out var pj))
                            a.ToolJson.Append(pj);
                        blocks[idx] = a;
                        break;
                    }
            }
        }

        var messageBlocks = new List<Block>();
        foreach (var (_, a) in blocks)
        {
            if (a.Type == "tool_use")
            {
                messageBlocks.Add(new Block.ToolUse(a.ToolName, a.ToolJson.ToString()));
            }
            else if (a.Text.Length > 0)
            {
                messageBlocks.Add(new Block.Text(a.Text.ToString()));
            }
        }
        return new Message(Role.Assistant, messageBlocks);
    }

    private struct AnthropicAccum
    {
        public string Type;
        public string ToolName;
        public StringBuilder Text;
        public StringBuilder ToolJson;
        public AnthropicAccum() { Type = "text"; ToolName = ""; Text = new(); ToolJson = new(); }
    }

    /// <summary>
    /// OpenAI dispatcher — picks Chat Completions vs the Responses API
    /// shape from the request body. When the request is missing we
    /// sniff the response: <c>choices[]</c> → Chat, <c>output[]</c> →
    /// Responses.
    /// </summary>
    private static Conversation? ParseOpenAi(byte[]? req, byte[]? res)
    {
        if (req is { Length: > 0 } && TryParseJsonObject(req, out var reqJson))
        {
            if (reqJson["messages"] is JsonArray) return ParseOpenAiChat(reqJson, res);
            if (reqJson["input"] is not null || reqJson["instructions"] is not null
                || reqJson["response"] is JsonObject)
            {
                return ParseOpenAiResponses(reqJson, res);
            }
        }
        if (res is { Length: > 0 } && TryParseJsonObject(res, out var resJson))
        {
            if (resJson["output"] is JsonArray) return ParseOpenAiResponses(null, res);
        }
        return ParseOpenAiChat(null, res);
    }

    private static Conversation? ParseOpenAiChat(JsonObject? reqJson, byte[]? res)
    {
        var convo = new Conversation { Provider = Provider.OpenAi };

        if (reqJson is not null)
        {
            convo.Model = reqJson["model"]?.GetValue<string>();
            if (reqJson["messages"] is JsonArray msgs)
            {
                foreach (var m in msgs.OfType<JsonObject>())
                {
                    var role = m["role"]?.GetValue<string>();
                    if (!TryParseRole(role, out var r)) continue;
                    var content = m["content"];
                    var blocks = OpenAiContentBlocks(content);
                    if (r == Role.System && blocks.Count == 1 && blocks[0] is Block.Text t)
                    {
                        // Promote the first system text block to the
                        // top-level systemPrompt for parity with
                        // Anthropic's structure.
                        if (string.IsNullOrEmpty(convo.SystemPrompt))
                        {
                            convo.SystemPrompt = t.Value;
                            continue;
                        }
                    }
                    convo.Messages.Add(new Message(r, blocks));
                }
            }
        }

        if (res is { Length: > 0 })
        {
            if (TryParseJsonObject(res, out var resJson))
            {
                if (resJson["choices"] is JsonArray choices && choices.Count > 0
                    && choices[0] is JsonObject c0
                    && c0["message"] is JsonObject m0)
                {
                    var role = m0["role"]?.GetValue<string>();
                    var blocks = OpenAiContentBlocks(m0["content"]);
                    var asstRole = TryParseRole(role, out var rr) ? rr : Role.Assistant;
                    convo.Messages.Add(new Message(asstRole, blocks));
                }
                if (resJson["usage"] is JsonObject usage)
                {
                    if (usage["prompt_tokens"] is JsonValue iv && iv.TryGetValue<int>(out var it))
                        convo.InputTokens = it;
                    if (usage["completion_tokens"] is JsonValue ov && ov.TryGetValue<int>(out var ot))
                        convo.OutputTokens = ot;
                }
            }
            else
            {
                var sseText = Encoding.UTF8.GetString(res);
                var assistant = ParseOpenAiChatSse(sseText);
                if (assistant.Content.Count > 0) convo.Messages.Add(assistant);
            }
        }

        return convo.Messages.Count == 0 && string.IsNullOrEmpty(convo.SystemPrompt)
            ? null
            : convo;
    }

    private static List<Block> OpenAiContentBlocks(JsonNode? content)
    {
        var blocks = new List<Block>();
        if (content is JsonValue sv && sv.TryGetValue<string>(out var s))
        {
            if (!string.IsNullOrEmpty(s)) blocks.Add(new Block.Text(s));
            return blocks;
        }
        if (content is JsonArray arr)
        {
            foreach (var item in arr.OfType<JsonObject>())
            {
                var type = item["type"]?.GetValue<string>();
                switch (type)
                {
                    case "text":
                        blocks.Add(new Block.Text(item["text"]?.GetValue<string>() ?? ""));
                        break;
                    case "image_url":
                        blocks.Add(new Block.Image(
                            mediaType: (item["image_url"] as JsonObject)?["url"]?.GetValue<string>() ?? "image/url"));
                        break;
                }
            }
        }
        return blocks;
    }

    /// <summary>
    /// Walk an OpenAI Chat Completions SSE stream and assemble the
    /// assistant turn from delta.content. Doesn't track function /
    /// tool calls yet (rare for chat-shaped clients; would need
    /// delta.tool_calls accumulation).
    /// </summary>
    private static Message ParseOpenAiChatSse(string text)
    {
        var sb = new StringBuilder();
        foreach (var chunk in text.Split("\n\n"))
        {
            var dataLine = chunk.Split('\n')
                .FirstOrDefault(l => l.StartsWith("data:", StringComparison.Ordinal));
            if (dataLine is null) continue;
            var data = dataLine["data:".Length..].Trim();
            if (data.Length == 0 || data == "[DONE]") continue;
            JsonObject? obj;
            try { obj = JsonNode.Parse(data) as JsonObject; }
            catch (JsonException) { continue; }
            if (obj is null) continue;
            if (obj["choices"] is not JsonArray choices) continue;
            if (choices.Count == 0 || choices[0] is not JsonObject c0) continue;
            if (c0["delta"] is not JsonObject delta) continue;
            if (delta["content"] is JsonValue cv && cv.TryGetValue<string>(out var s)) sb.Append(s);
        }
        var blocks = new List<Block>();
        if (sb.Length > 0) blocks.Add(new Block.Text(sb.ToString()));
        return new Message(Role.Assistant, blocks);
    }

    // -- WebSocket transcript walker --------------------------------------

    /// <summary>
    /// Walk a WebSocket trace transcript in chronological order and
    /// build the conversation directly. Currently OpenAI-Responses-
    /// shaped only — the only WS LLM protocol we capture. Returns
    /// null when the body isn't a transcript or the host doesn't
    /// match, so the caller falls through to synthesize-and-route.
    /// </summary>
    private static Conversation? ParseWebSocketTranscript(string host, byte[]? responseBody)
    {
        if (responseBody is null || responseBody.Length == 0) return null;
        var text = Encoding.UTF8.GetString(responseBody);
        if (!text.Contains("--- WebSocket session transcript ---")) return null;

        var h = host.ToLowerInvariant();
        if (!(h.Contains("openai.com") || h.Contains("mistral.ai")
              || h.Contains("x.ai") || h.Contains("groq.com")
              || h.Contains("perplexity.ai")))
        {
            return null;
        }

        // Walk the transcript collecting (direction, body) tuples in
        // arrival order. Format mirrors macOS:
        //   >>> [timestamp] KIND BB
        //   <json...>
        //   <<< [timestamp] KIND BB
        //   <json...>
        var events = new List<(bool ClientToUpstream, string Json)>();
        bool? direction = null;
        var buffer = new StringBuilder();
        foreach (var rawLine in text.Split('\n'))
        {
            if (rawLine.StartsWith(">>>", StringComparison.Ordinal))
            {
                FlushTranscriptEvent(direction, buffer, events);
                direction = true;
                continue;
            }
            if (rawLine.StartsWith("<<<", StringComparison.Ordinal))
            {
                FlushTranscriptEvent(direction, buffer, events);
                direction = false;
                continue;
            }
            if (direction is null) continue;
            buffer.Append(rawLine).Append('\n');
        }
        FlushTranscriptEvent(direction, buffer, events);
        if (events.Count == 0) return null;

        var convo = new Conversation { Provider = Provider.OpenAi };

        // Per-turn assistant accumulator. Flushed on response.completed
        // (or end-of-transcript for an interrupted final turn).
        var pendingText = new StringBuilder();
        var pendingTools = new Dictionary<string, ResponsesAccum>();
        var pendingOrder = new List<string>();
        var emitted = new HashSet<string>(StringComparer.Ordinal);
        JsonObject? firstClientObj = null;

        void FlushAssistant()
        {
            var blocks = new List<Block>();
            if (pendingText.Length > 0) blocks.Add(new Block.Text(pendingText.ToString()));
            foreach (var id in pendingOrder)
            {
                var t = pendingTools[id];
                blocks.Add(new Block.ToolUse(t.Name!, t.Args!.ToString()));
            }
            if (blocks.Count > 0) convo.Messages.Add(new Message(Role.Assistant, blocks));
            pendingText.Clear();
            pendingTools.Clear();
            pendingOrder.Clear();
        }

        foreach (var (c2u, json) in events)
        {
            JsonObject? obj;
            try { obj = JsonNode.Parse(json) as JsonObject; }
            catch (JsonException) { continue; }
            if (obj is null) continue;

            if (c2u)
            {
                firstClientObj ??= obj;
                if (string.IsNullOrEmpty(convo.Model))
                {
                    convo.Model = obj["model"]?.GetValue<string>()
                        ?? (obj["response"] as JsonObject)?["model"]?.GetValue<string>();
                }
                if (string.IsNullOrEmpty(convo.SystemPrompt))
                {
                    convo.SystemPrompt = obj["instructions"]?.GetValue<string>()
                        ?? (obj["response"] as JsonObject)?["instructions"]?.GetValue<string>();
                }
                // A new turn started — flush any in-flight assistant
                // from the prior turn first so the new user message
                // lands AFTER the prior reply.
                if (pendingText.Length > 0 || pendingTools.Count > 0) FlushAssistant();

                var candidates = new JsonNode?[]
                {
                    obj["input"], obj["messages"],
                    (obj["response"] as JsonObject)?["input"],
                    (obj["response"] as JsonObject)?["messages"],
                };
                foreach (var c in candidates)
                {
                    if (c is JsonArray items)
                    {
                        foreach (var item in items.OfType<JsonObject>())
                        {
                            var fp = TranscriptFingerprint(item);
                            if (!emitted.Add(fp)) continue;
                            var blocks = ResponsesItemBlocks(item);
                            if (blocks.Count == 0) continue;
                            var role = MapResponsesRole(item["role"]?.GetValue<string>());
                            convo.Messages.Add(new Message(role, blocks));
                        }
                        break;
                    }
                    if (c is JsonValue v && v.TryGetValue<string>(out var s) && s.Length > 0)
                    {
                        var fp = "user:" + s;
                        if (emitted.Add(fp))
                        {
                            convo.Messages.Add(new Message(Role.User,
                                new[] { (Block)new Block.Text(s) }));
                        }
                        break;
                    }
                }
            }
            else
            {
                var type = obj["type"]?.GetValue<string>() ?? "";
                switch (type)
                {
                    case "response.output_text.delta":
                        if (obj["delta"] is JsonValue dv && dv.TryGetValue<string>(out var d))
                            pendingText.Append(d);
                        break;
                    case "response.function_call_arguments.delta":
                        {
                            var id = obj["item_id"]?.GetValue<string>() ?? "tool";
                            var delta = obj["delta"]?.GetValue<string>() ?? "";
                            if (!pendingTools.ContainsKey(id))
                            {
                                pendingTools[id] = new ResponsesAccum { Name = "tool", Args = new StringBuilder() };
                                pendingOrder.Add(id);
                            }
                            pendingTools[id].Args!.Append(delta);
                            break;
                        }
                    case "response.output_item.added":
                        {
                            if (obj["item"] is not JsonObject item) break;
                            var name = item["name"]?.GetValue<string>();
                            if (name is null) break;
                            var id = item["id"]?.GetValue<string>()
                                ?? item["call_id"]?.GetValue<string>()
                                ?? name;
                            if (pendingTools.TryGetValue(id, out var existing))
                            {
                                existing.Name = name;
                            }
                            else
                            {
                                pendingTools[id] = new ResponsesAccum { Name = name, Args = new StringBuilder() };
                                pendingOrder.Add(id);
                            }
                            break;
                        }
                    case "response.completed":
                        {
                            if ((obj["response"] as JsonObject)?["usage"] is JsonObject usage)
                            {
                                if (convo.InputTokens is null
                                    && usage["input_tokens"] is JsonValue iv && iv.TryGetValue<int>(out var it))
                                    convo.InputTokens = it;
                                if (convo.OutputTokens is null
                                    && usage["output_tokens"] is JsonValue ov && ov.TryGetValue<int>(out var ot))
                                    convo.OutputTokens = ot;
                            }
                            FlushAssistant();
                            break;
                        }
                }
            }
        }
        FlushAssistant();

        if (firstClientObj is not null)
        {
            convo.RequestEnvelope = firstClientObj.ToJsonString(
                new JsonSerializerOptions { WriteIndented = true });
        }
        if (convo.Messages.Count == 0
            && string.IsNullOrEmpty(convo.SystemPrompt)
            && string.IsNullOrEmpty(convo.RequestEnvelope))
        {
            return null;
        }
        return convo;
    }

    private static void FlushTranscriptEvent(
        bool? direction, StringBuilder buffer, List<(bool, string)> events)
    {
        if (direction is null) return;
        var body = buffer.ToString().Trim();
        buffer.Clear();
        if (body.Length > 0) events.Add((direction.Value, body));
    }

    /// <summary>Stable string fingerprint of a Responses-API input
    /// item, used to dedup repeated history items across compacted
    /// turns. JSON serialization with sort isn't a primitive in
    /// JsonNode; ordinal serialization is acceptable here because
    /// the compactor copies items verbatim — comparing the rendered
    /// JSON in the order they ship matches byte-for-byte.</summary>
    private static string TranscriptFingerprint(JsonObject item)
        => item.ToJsonString();

    // -- OpenAI Responses API ---------------------------------------------

    /// <summary>
    /// /v1/responses parser — Codex traffic + newer OpenAI SDKs. The
    /// request shape uses <c>input</c> (string or array of items) and
    /// <c>instructions</c> (system prompt). Response carries an
    /// <c>output</c> array with mixed message + function_call items.
    /// Matches macOS <c>parseOpenAIResponses</c>.
    /// </summary>
    private static Conversation? ParseOpenAiResponses(JsonObject? reqJson, byte[]? res)
    {
        var convo = new Conversation { Provider = Provider.OpenAi };

        if (reqJson is not null)
        {
            convo.Model = reqJson["model"]?.GetValue<string>()
                ?? (reqJson["response"] as JsonObject)?["model"]?.GetValue<string>();
            convo.SystemPrompt = reqJson["instructions"]?.GetValue<string>()
                ?? (reqJson["response"] as JsonObject)?["instructions"]?.GetValue<string>();

            // Try every shape we've seen ship as the conversation
            // history; first non-empty one wins.
            var candidates = new JsonNode?[]
            {
                reqJson["input"],
                reqJson["messages"],
                (reqJson["response"] as JsonObject)?["input"],
                (reqJson["response"] as JsonObject)?["messages"],
            };
            foreach (var c in candidates)
            {
                if (c is JsonValue v && v.TryGetValue<string>(out var s) && s.Length > 0)
                {
                    convo.Messages.Add(new Message(Role.User, new[] { (Block)new Block.Text(s) }));
                    break;
                }
                if (c is JsonArray items)
                {
                    var added = false;
                    foreach (var item in items.OfType<JsonObject>())
                    {
                        var blocks = ResponsesItemBlocks(item);
                        if (blocks.Count == 0) continue;
                        var role = MapResponsesRole(item["role"]?.GetValue<string>());
                        convo.Messages.Add(new Message(role, blocks));
                        added = true;
                    }
                    if (added) break;
                }
            }

            // Always capture the raw envelope for the inspector.
            convo.RequestEnvelope = reqJson.ToJsonString(
                new JsonSerializerOptions { WriteIndented = true });
        }

        if (res is { Length: > 0 })
        {
            if (TryParseJsonObject(res, out var resJson))
            {
                if (resJson["output"] is JsonArray output)
                {
                    foreach (var item in output.OfType<JsonObject>())
                    {
                        var blocks = ResponsesItemBlocks(item);
                        if (blocks.Count == 0) continue;
                        var role = MapResponsesRole(item["role"]?.GetValue<string>());
                        convo.Messages.Add(new Message(role, blocks));
                    }
                }
                if (resJson["usage"] is JsonObject usage)
                {
                    if (usage["input_tokens"] is JsonValue iv && iv.TryGetValue<int>(out var it))
                        convo.InputTokens = it;
                    if (usage["output_tokens"] is JsonValue ov && ov.TryGetValue<int>(out var ot))
                        convo.OutputTokens = ot;
                }
            }
            else
            {
                var sse = Encoding.UTF8.GetString(res);
                var assistant = ParseOpenAiResponsesSse(sse);
                if (assistant.Content.Count > 0) convo.Messages.Add(assistant);
            }
        }

        if (convo.Messages.Count == 0
            && string.IsNullOrEmpty(convo.SystemPrompt)
            && string.IsNullOrEmpty(convo.RequestEnvelope))
        {
            return null;
        }
        return convo;
    }

    private static Role MapResponsesRole(string? raw) => raw switch
    {
        "system" or "developer" => Role.System,
        "assistant"             => Role.Assistant,
        "tool" or "function"    => Role.Tool,
        _                       => Role.User,
    };

    /// <summary>
    /// One item in the Responses input/output array. Items can be plain
    /// message text, structured content blocks, function/tool calls, or
    /// function/tool outputs.
    /// </summary>
    private static List<Block> ResponsesItemBlocks(JsonObject item)
    {
        var type = item["type"]?.GetValue<string>();
        if (type is "function_call" or "tool_call")
        {
            var name = item["name"]?.GetValue<string>()
                ?? item["call_id"]?.GetValue<string>()
                ?? "tool";
            string args;
            if (item["arguments"] is JsonValue av && av.TryGetValue<string>(out var s))
            {
                args = s;
            }
            else if (item["arguments"] is JsonObject obj)
            {
                args = obj.ToJsonString(new JsonSerializerOptions { WriteIndented = true });
            }
            else { args = ""; }
            return new List<Block> { new Block.ToolUse(name, args) };
        }
        if (type is "function_call_output" or "tool_call_output" or "function_output")
        {
            var id = item["call_id"]?.GetValue<string>();
            var output = item["output"]?.GetValue<string>() ?? "";
            return new List<Block> { new Block.ToolResult(id, output, false) };
        }

        // Regular message: content is a string or an array of typed blocks.
        if (item["content"] is JsonValue cv && cv.TryGetValue<string>(out var cs))
            return new List<Block> { new Block.Text(cs) };
        var blocks = new List<Block>();
        if (item["content"] is JsonArray arr)
        {
            foreach (var part in arr.OfType<JsonObject>())
            {
                var t = part["type"]?.GetValue<string>();
                switch (t)
                {
                    case "input_text":
                    case "output_text":
                    case "text":
                        if (part["text"]?.GetValue<string>() is { } txt) blocks.Add(new Block.Text(txt));
                        break;
                    case "input_image":
                    case "image":
                        blocks.Add(new Block.Image("image"));
                        break;
                }
            }
        }
        return blocks;
    }

    /// <summary>
    /// SSE for /v1/responses. <c>response.output_text.delta</c> chunks
    /// accumulate the assistant text; tool-call argument deltas land
    /// on <c>response.function_call_arguments.delta</c>, keyed by
    /// item id so multi-tool turns reassemble correctly. The function
    /// name comes in via <c>response.output_item.added</c>.
    /// </summary>
    private static Message ParseOpenAiResponsesSse(string text)
    {
        var combined = new StringBuilder();
        var toolByItem = new Dictionary<string, ResponsesAccum>();
        var toolOrder = new List<string>();

        foreach (var chunk in text.Split("\n\n"))
        {
            string ev = "", dataStr = "";
            foreach (var line in chunk.Split('\n'))
            {
                if (line.StartsWith("event:", StringComparison.Ordinal))
                    ev = line["event:".Length..].Trim();
                else if (line.StartsWith("data:", StringComparison.Ordinal))
                {
                    var v = line["data:".Length..].Trim();
                    dataStr = dataStr.Length == 0 ? v : dataStr + "\n" + v;
                }
            }
            if (dataStr.Length == 0) continue;
            JsonObject? obj;
            try { obj = JsonNode.Parse(dataStr) as JsonObject; }
            catch (JsonException) { continue; }
            if (obj is null) continue;
            switch (ev)
            {
                case "response.output_text.delta":
                    if (obj["delta"] is JsonValue dv && dv.TryGetValue<string>(out var d))
                        combined.Append(d);
                    break;
                case "response.function_call_arguments.delta":
                    {
                        var id = obj["item_id"]?.GetValue<string>() ?? "tool";
                        if (!toolByItem.ContainsKey(id))
                        {
                            toolByItem[id] = new ResponsesAccum { Name = id, Args = new StringBuilder() };
                            toolOrder.Add(id);
                        }
                        if (obj["delta"] is JsonValue av && av.TryGetValue<string>(out var ad))
                            toolByItem[id].Args!.Append(ad);
                        break;
                    }
                case "response.output_item.added":
                    {
                        if (obj["item"] is not JsonObject item) break;
                        if (item["type"]?.GetValue<string>() != "function_call") break;
                        var id = item["id"]?.GetValue<string>();
                        var name = item["name"]?.GetValue<string>();
                        if (id is null || name is null) break;
                        if (toolByItem.TryGetValue(id, out var existing))
                        {
                            existing.Name = name;
                        }
                        else
                        {
                            toolByItem[id] = new ResponsesAccum { Name = name, Args = new StringBuilder() };
                            toolOrder.Add(id);
                        }
                        break;
                    }
            }
        }

        var blocks = new List<Block>();
        if (combined.Length > 0) blocks.Add(new Block.Text(combined.ToString()));
        foreach (var id in toolOrder)
        {
            var t = toolByItem[id];
            blocks.Add(new Block.ToolUse(t.Name!, t.Args!.ToString()));
        }
        return new Message(Role.Assistant, blocks);
    }

    private sealed class ResponsesAccum
    {
        public string? Name;
        public StringBuilder? Args;
    }

    // -- Gemini -----------------------------------------------------------

    /// <summary>
    /// generativelanguage.googleapis.com — request carries
    /// <c>contents</c> (alternating user/model parts) and an optional
    /// <c>systemInstruction.parts[].text</c>. Response is
    /// <c>candidates[].content.parts[].text</c>.
    /// </summary>
    private static Conversation? ParseGemini(byte[]? req, byte[]? res)
    {
        var convo = new Conversation { Provider = Provider.Gemini };

        if (req is { Length: > 0 } && TryParseJsonObject(req, out var reqJson))
        {
            if ((reqJson["systemInstruction"] as JsonObject)?["parts"] is JsonArray sysParts)
            {
                var texts = sysParts.OfType<JsonObject>()
                    .Select(p => p["text"]?.GetValue<string>())
                    .Where(t => !string.IsNullOrEmpty(t))
                    .ToList();
                if (texts.Count > 0) convo.SystemPrompt = string.Join("\n\n", texts);
            }
            if (reqJson["contents"] is JsonArray contents)
            {
                foreach (var c in contents.OfType<JsonObject>())
                {
                    var role = c["role"]?.GetValue<string>() ?? "user";
                    var r = role == "model" ? Role.Assistant : Role.User;
                    var parts = c["parts"] as JsonArray;
                    var blocks = parts is null
                        ? new List<Block>()
                        : parts.OfType<JsonObject>()
                            .Select(p => p["text"]?.GetValue<string>())
                            .Where(t => !string.IsNullOrEmpty(t))
                            .Select(t => (Block)new Block.Text(t!))
                            .ToList();
                    convo.Messages.Add(new Message(r, blocks));
                }
            }
        }
        if (res is { Length: > 0 } && TryParseJsonObject(res, out var resJson))
        {
            if (resJson["candidates"] is JsonArray cands)
            {
                foreach (var c in cands.OfType<JsonObject>())
                {
                    if ((c["content"] as JsonObject)?["parts"] is not JsonArray parts) continue;
                    var blocks = parts.OfType<JsonObject>()
                        .Select(p => p["text"]?.GetValue<string>())
                        .Where(t => !string.IsNullOrEmpty(t))
                        .Select(t => (Block)new Block.Text(t!))
                        .ToList();
                    convo.Messages.Add(new Message(Role.Assistant, blocks));
                }
            }
        }
        return convo.Messages.Count == 0 ? null : convo;
    }

    // -- Cohere -----------------------------------------------------------

    /// <summary>
    /// api.cohere.com /v1/chat. Request: <c>{ message, chat_history,
    /// preamble }</c> with chat_history role values <c>USER</c> /
    /// <c>CHATBOT</c>. Response: <c>{ text, meta.tokens.{input,
    /// output}_tokens }</c>.
    /// </summary>
    private static Conversation? ParseCohere(byte[]? req, byte[]? res)
    {
        var convo = new Conversation { Provider = Provider.Cohere };

        if (req is { Length: > 0 } && TryParseJsonObject(req, out var reqJson))
        {
            convo.Model = reqJson["model"]?.GetValue<string>();
            if (reqJson["preamble"]?.GetValue<string>() is { Length: > 0 } pre)
                convo.SystemPrompt = pre;
            if (reqJson["chat_history"] is JsonArray history)
            {
                foreach (var h in history.OfType<JsonObject>())
                {
                    var role = (h["role"]?.GetValue<string>() ?? "USER").ToUpperInvariant();
                    var r = (role == "CHATBOT" || role == "ASSISTANT") ? Role.Assistant : Role.User;
                    if (h["message"]?.GetValue<string>() is { } msg)
                    {
                        convo.Messages.Add(new Message(r, new[] { (Block)new Block.Text(msg) }));
                    }
                }
            }
            if (reqJson["message"]?.GetValue<string>() is { } cur)
            {
                convo.Messages.Add(new Message(Role.User, new[] { (Block)new Block.Text(cur) }));
            }
        }
        if (res is { Length: > 0 } && TryParseJsonObject(res, out var resJson))
        {
            if (resJson["text"]?.GetValue<string>() is { Length: > 0 } txt)
            {
                convo.Messages.Add(new Message(Role.Assistant,
                    new[] { (Block)new Block.Text(txt) }));
            }
            if ((resJson["meta"] as JsonObject)?["tokens"] is JsonObject tokens)
            {
                if (tokens["input_tokens"] is JsonValue iv && iv.TryGetValue<int>(out var it))
                    convo.InputTokens = it;
                if (tokens["output_tokens"] is JsonValue ov && ov.TryGetValue<int>(out var ot))
                    convo.OutputTokens = ot;
            }
        }
        return convo.Messages.Count == 0 ? null : convo;
    }

    // -- Helpers ----------------------------------------------------------

    private static bool TryParseRole(string? raw, out Role role)
    {
        role = Role.User;
        if (string.IsNullOrEmpty(raw)) return false;
        switch (raw.ToLowerInvariant())
        {
            case "system":    role = Role.System;    return true;
            case "user":      role = Role.User;      return true;
            case "assistant": role = Role.Assistant; return true;
            case "tool":      role = Role.Tool;      return true;
            default:          return false;
        }
    }

    private static bool TryParseJsonObject(byte[] bytes, out JsonObject obj)
    {
        obj = null!;
        try
        {
            var node = JsonNode.Parse(bytes);
            if (node is JsonObject jo) { obj = jo; return true; }
        }
        catch (JsonException) { }
        return false;
    }

    /// <summary>
    /// Strip the <c>HTTP/1.1 200 OK\r\n…\r\n\r\n</c> framing from a
    /// raw wire frame, returning just the body. Returns the input
    /// untouched when no <c>\r\n\r\n</c> separator is present (caller
    /// passes a body that isn't HTTP-framed).
    /// </summary>
    private static byte[]? StripHttpFraming(byte[]? raw)
    {
        if (raw is null || raw.Length == 0) return raw;
        var idx = IndexOfHeaderEnd(raw);
        if (idx < 0) return raw;
        var bodyStart = idx + 4;
        var body = new byte[raw.Length - bodyStart];
        Buffer.BlockCopy(raw, bodyStart, body, 0, body.Length);
        return body;
    }

    private static int IndexOfHeaderEnd(byte[] raw)
    {
        for (var i = 0; i <= raw.Length - 4; i++)
        {
            if (raw[i] == 0x0D && raw[i + 1] == 0x0A
                && raw[i + 2] == 0x0D && raw[i + 3] == 0x0A) return i;
        }
        return -1;
    }
}
