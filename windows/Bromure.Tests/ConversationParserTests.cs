using System.Text;
using System.Text.Json.Nodes;
using Bromure.AC.Mitm.Conversation;
using FluentAssertions;
using Xunit;

namespace Bromure.Tests;

public class ConversationParserTests
{
    private static byte[] U(string s) => Encoding.UTF8.GetBytes(s);

    [Fact]
    public void Anthropic_full_response_yields_assistant_text_and_tokens()
    {
        var req = U("""{"model":"claude-3-5-sonnet","messages":[{"role":"user","content":"hi"}]}""");
        var res = U("""
            {"content":[{"type":"text","text":"hello back"}],
             "usage":{"input_tokens":12,"output_tokens":3}}
            """);
        var c = ConversationParser.Parse("api.anthropic.com", req, res);
        c.Should().NotBeNull();
        c!.Provider.Should().Be(Provider.Anthropic);
        c.Model.Should().Be("claude-3-5-sonnet");
        c.InputTokens.Should().Be(12);
        c.OutputTokens.Should().Be(3);
        c.Messages.Should().HaveCount(2);
        c.Messages.Last().Role.Should().Be(Role.Assistant);
        c.Messages.Last().Content.OfType<Block.Text>().Single().Value.Should().Be("hello back");
    }

    [Fact]
    public void Anthropic_system_string_promoted()
    {
        var req = U("""{"model":"claude-3-5-sonnet","system":"be brief","messages":[{"role":"user","content":"hi"}]}""");
        var c = ConversationParser.Parse("api.anthropic.com", req, null);
        c!.SystemPrompt.Should().Be("be brief");
    }

    [Fact]
    public void Anthropic_system_array_joined_with_blank_line()
    {
        var req = U("""{"system":[{"type":"text","text":"first"},{"type":"text","text":"second"}],"messages":[{"role":"user","content":"q"}]}""");
        var c = ConversationParser.Parse("api.anthropic.com", req, null);
        c!.SystemPrompt.Should().Be("first\n\nsecond");
    }

    [Fact]
    public void Anthropic_sse_assembles_text_and_tool_use_in_order()
    {
        // index 0: text; index 1: tool_use accumulating partial_json.
        var sse = string.Join("\n\n",
            "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\"}}",
            "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"text\":\"hello \"}}",
            "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"text\":\"world\"}}",
            "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"name\":\"Read\"}}",
            "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"partial_json\":\"{\\\"path\\\":\"}}",
            "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"partial_json\":\"\\\"/tmp/x\\\"}\"}}");
        var c = ConversationParser.Parse("api.anthropic.com", null, U(sse));
        c.Should().NotBeNull();
        var assistant = c!.Messages.Single();
        assistant.Role.Should().Be(Role.Assistant);
        assistant.Content.Should().HaveCount(2);
        ((Block.Text)assistant.Content[0]).Value.Should().Be("hello world");
        var tool = (Block.ToolUse)assistant.Content[1];
        tool.Name.Should().Be("Read");
        tool.Input.Should().Be("{\"path\":\"/tmp/x\"}");
    }

    [Fact]
    public void Anthropic_tool_result_block_round_trips()
    {
        var req = U("""
            {"messages":[
              {"role":"user","content":[
                {"type":"tool_result","tool_use_id":"u1","content":"output here","is_error":false}
              ]}
            ]}
            """);
        var c = ConversationParser.Parse("api.anthropic.com", req, null);
        var tr = c!.Messages.Single().Content.OfType<Block.ToolResult>().Single();
        tr.ToolUseId.Should().Be("u1");
        tr.Content.Should().Be("output here");
        tr.IsError.Should().BeFalse();
    }

    [Fact]
    public void Strips_http_framing_before_parsing()
    {
        var framed = U(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n" +
            "{\"content\":[{\"type\":\"text\",\"text\":\"x\"}]}");
        var c = ConversationParser.Parse("api.anthropic.com", null, framed);
        c.Should().NotBeNull();
        ((Block.Text)c!.Messages.Single().Content.Single()).Value.Should().Be("x");
    }

    [Fact]
    public void OpenAi_chat_full_response_promotes_system_prompt()
    {
        var req = U("""
            {"model":"gpt-4o","messages":[
              {"role":"system","content":"be brief"},
              {"role":"user","content":"hi"}
            ]}
            """);
        var res = U("""
            {"choices":[{"message":{"role":"assistant","content":"yo"}}],
             "usage":{"prompt_tokens":4,"completion_tokens":1}}
            """);
        var c = ConversationParser.Parse("api.openai.com", req, res);
        c.Should().NotBeNull();
        c!.Provider.Should().Be(Provider.OpenAi);
        c.Model.Should().Be("gpt-4o");
        c.SystemPrompt.Should().Be("be brief");
        c.Messages.Last().Role.Should().Be(Role.Assistant);
        c.InputTokens.Should().Be(4);
        c.OutputTokens.Should().Be(1);
    }

    [Fact]
    public void OpenAi_chat_sse_concatenates_deltas_and_skips_done()
    {
        var sse = string.Join("\n\n",
            "data: {\"choices\":[{\"delta\":{\"content\":\"hel\"}}]}",
            "data: {\"choices\":[{\"delta\":{\"content\":\"lo\"}}]}",
            "data: [DONE]");
        var c = ConversationParser.Parse("api.openai.com", null, U(sse));
        ((Block.Text)c!.Messages.Single().Content.Single()).Value.Should().Be("hello");
    }

    [Fact]
    public void OpenAi_responses_promotes_instructions_and_string_input()
    {
        var req = U("""{"model":"o1","input":"hello","instructions":"be brief"}""");
        var c = ConversationParser.Parse("api.openai.com", req, null);
        c.Should().NotBeNull();
        c!.Provider.Should().Be(Provider.OpenAi);
        c.Model.Should().Be("o1");
        c.SystemPrompt.Should().Be("be brief");
        c.Messages.Should().HaveCount(1);
        ((Block.Text)c.Messages[0].Content.Single()).Value.Should().Be("hello");
        c.RequestEnvelope.Should().Contain("\"instructions\"");
    }

    [Fact]
    public void OpenAi_responses_full_response_walks_output_array()
    {
        var req = U("""{"model":"o1","input":"hi"}""");
        var res = U("""
            {"output":[
              {"type":"message","role":"assistant","content":[{"type":"output_text","text":"hi back"}]},
              {"type":"function_call","id":"i1","name":"Read","arguments":"{\"file_path\":\"/x\"}"}
            ],"usage":{"input_tokens":7,"output_tokens":2}}
            """);
        var c = ConversationParser.Parse("api.openai.com", req, res);
        c.Should().NotBeNull();
        c!.InputTokens.Should().Be(7);
        c.OutputTokens.Should().Be(2);
        // function_call items lack a role field → MapResponsesRole
        // returns User (matches macOS). The text bubble is the
        // assistant message; the tool_use lands separately.
        var assistantText = c.Messages.Single(m => m.Role == Role.Assistant);
        ((Block.Text)assistantText.Content.Single()).Value.Should().Be("hi back");
        var toolUse = c.Messages.SelectMany(m => m.Content).OfType<Block.ToolUse>().Single();
        toolUse.Name.Should().Be("Read");
        toolUse.Input.Should().Be("{\"file_path\":\"/x\"}");
    }

    [Fact]
    public void OpenAi_responses_sse_assembles_text_and_tool_call_args_by_item_id()
    {
        var sse = string.Join("\n\n",
            "event: response.output_text.delta\ndata: {\"delta\":\"hel\"}",
            "event: response.output_text.delta\ndata: {\"delta\":\"lo\"}",
            "event: response.output_item.added\ndata: {\"item\":{\"id\":\"i1\",\"type\":\"function_call\",\"name\":\"Bash\"}}",
            "event: response.function_call_arguments.delta\ndata: {\"item_id\":\"i1\",\"delta\":\"{\\\"command\\\":\"}",
            "event: response.function_call_arguments.delta\ndata: {\"item_id\":\"i1\",\"delta\":\"\\\"ls\\\"}\"}");
        // The dispatcher needs the request to recognize Responses
        // shape; pass an empty input request.
        var req = U("""{"input":""}""");
        var c = ConversationParser.Parse("api.openai.com", req, U(sse));
        c.Should().NotBeNull();
        var assistant = c!.Messages.Single(m => m.Role == Role.Assistant);
        ((Block.Text)assistant.Content[0]).Value.Should().Be("hello");
        var tu = (Block.ToolUse)assistant.Content[1];
        tu.Name.Should().Be("Bash");
        tu.Input.Should().Be("{\"command\":\"ls\"}");
    }

    [Fact]
    public void Gemini_request_response_round_trip()
    {
        var req = U("""
            {"systemInstruction":{"parts":[{"text":"be terse"}]},
             "contents":[
               {"role":"user","parts":[{"text":"hi"}]},
               {"role":"model","parts":[{"text":"hello"}]}
             ]}
            """);
        var res = U("""
            {"candidates":[{"content":{"parts":[{"text":"sure"}]}}]}
            """);
        var c = ConversationParser.Parse("generativelanguage.googleapis.com", req, res);
        c.Should().NotBeNull();
        c!.Provider.Should().Be(Provider.Gemini);
        c.SystemPrompt.Should().Be("be terse");
        c.Messages.Should().HaveCount(3);
        c.Messages[0].Role.Should().Be(Role.User);
        c.Messages[1].Role.Should().Be(Role.Assistant);
        ((Block.Text)c.Messages[2].Content.Single()).Value.Should().Be("sure");
    }

    [Fact]
    public void Cohere_request_response_round_trip()
    {
        var req = U("""
            {"model":"command-r","preamble":"be brief",
             "chat_history":[{"role":"USER","message":"prev"},
                              {"role":"CHATBOT","message":"prev reply"}],
             "message":"new turn"}
            """);
        var res = U("""
            {"text":"done","meta":{"tokens":{"input_tokens":15,"output_tokens":2}}}
            """);
        var c = ConversationParser.Parse("api.cohere.com", req, res);
        c.Should().NotBeNull();
        c!.Provider.Should().Be(Provider.Cohere);
        c.Model.Should().Be("command-r");
        c.SystemPrompt.Should().Be("be brief");
        c.InputTokens.Should().Be(15);
        c.OutputTokens.Should().Be(2);
        c.Messages.Should().HaveCount(4);
        c.Messages[0].Role.Should().Be(Role.User);
        c.Messages[1].Role.Should().Be(Role.Assistant);
        c.Messages[2].Role.Should().Be(Role.User);
        ((Block.Text)c.Messages[2].Content.Single()).Value.Should().Be("new turn");
        c.Messages[3].Role.Should().Be(Role.Assistant);
        ((Block.Text)c.Messages[3].Content.Single()).Value.Should().Be("done");
    }

    [Fact]
    public void WebSocket_transcript_walks_turns_in_order()
    {
        // Two-turn session: user₁ → assistant₁ (text + tool) →
        // user₂ → assistant₂ (text). Walker must interleave correctly
        // even though both responses share the same SSE-shaped events.
        var transcript = string.Join('\n',
            "--- WebSocket session transcript ---",
            ">>> [2026-05-06T00:00:00Z] TEXT 1B",
            "{\"type\":\"response.create\",\"model\":\"gpt-4o-realtime\"," +
              "\"instructions\":\"be brief\",\"input\":[{\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"q1\"}]}]}",
            "<<< [2026-05-06T00:00:01Z] TEXT 1B",
            "{\"type\":\"response.output_text.delta\",\"delta\":\"a1\"}",
            "<<< [2026-05-06T00:00:02Z] TEXT 1B",
            "{\"type\":\"response.completed\",\"response\":{\"usage\":{\"input_tokens\":3,\"output_tokens\":1}}}",
            ">>> [2026-05-06T00:00:03Z] TEXT 1B",
            "{\"type\":\"response.create\",\"input\":[{\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"q2\"}]}]}",
            "<<< [2026-05-06T00:00:04Z] TEXT 1B",
            "{\"type\":\"response.output_text.delta\",\"delta\":\"a2\"}",
            "<<< [2026-05-06T00:00:05Z] TEXT 1B",
            "{\"type\":\"response.completed\"}");
        var c = ConversationParser.Parse("api.openai.com", null, U(transcript));
        c.Should().NotBeNull();
        c!.Provider.Should().Be(Provider.OpenAi);
        c.Model.Should().Be("gpt-4o-realtime");
        c.SystemPrompt.Should().Be("be brief");
        c.InputTokens.Should().Be(3);
        c.OutputTokens.Should().Be(1);
        c.Messages.Should().HaveCount(4);
        c.Messages[0].Role.Should().Be(Role.User);
        ((Block.Text)c.Messages[0].Content.Single()).Value.Should().Be("q1");
        c.Messages[1].Role.Should().Be(Role.Assistant);
        ((Block.Text)c.Messages[1].Content.Single()).Value.Should().Be("a1");
        c.Messages[2].Role.Should().Be(Role.User);
        ((Block.Text)c.Messages[2].Content.Single()).Value.Should().Be("q2");
        c.Messages[3].Role.Should().Be(Role.Assistant);
        ((Block.Text)c.Messages[3].Content.Single()).Value.Should().Be("a2");
    }

    [Fact]
    public void WebSocket_transcript_dedups_repeated_history_items()
    {
        // Codex-style compaction repeats prior turns in subsequent
        // input arrays. The walker must dedup so the same user
        // message doesn't show up twice.
        var transcript = string.Join('\n',
            "--- WebSocket session transcript ---",
            ">>> [2026-05-06T00:00:00Z] TEXT 1B",
            "{\"input\":[{\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"hi\"}]}]}",
            ">>> [2026-05-06T00:00:01Z] TEXT 1B",
            "{\"input\":[{\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"hi\"}]}," +
              "{\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"again\"}]}]}");
        var c = ConversationParser.Parse("api.openai.com", null, U(transcript));
        c.Should().NotBeNull();
        c!.Messages.Where(m => m.Role == Role.User)
            .Select(m => ((Block.Text)m.Content.Single()).Value)
            .Should().Equal(new[] { "hi", "again" });
    }

    [Fact]
    public void WebSocket_transcript_falls_through_for_non_openai_host()
    {
        var transcript = "--- WebSocket session transcript ---\n>>>\n{}\n";
        ConversationParser.Parse("api.anthropic.com", null, U(transcript))
            .Should().BeNull();
    }

    [Fact]
    public void Unknown_host_returns_null()
    {
        ConversationParser.Parse("example.com", U("{}"), U("{}")).Should().BeNull();
    }

    [Fact]
    public void Empty_bodies_return_null()
    {
        ConversationParser.Parse("api.anthropic.com", null, null).Should().BeNull();
    }
}

public class ConversationEventEmitterTests
{
    [Fact]
    public void Emits_llm_request_with_provider_host_status_latency()
    {
        var convo = new Conversation
        {
            Provider = Provider.Anthropic,
            Model = "claude-3-5-sonnet",
            InputTokens = 10,
            OutputTokens = 5,
        };
        var captured = new List<(string Type, JsonObject Data)>();
        ConversationEventEmitter.Emit(
            Guid.NewGuid(), "api.anthropic.com", "/v1/messages", 200, 123.4,
            responseBody: null, convo,
            emit: (_, t, d) => captured.Add((t, d)));

        captured.Should().ContainSingle();
        captured[0].Type.Should().Be("llm.request");
        var d = captured[0].Data;
        d["provider"]!.GetValue<string>().Should().Be("anthropic");
        d["host"]!.GetValue<string>().Should().Be("api.anthropic.com");
        d["path"]!.GetValue<string>().Should().Be("/v1/messages");
        d["status_code"]!.GetValue<int>().Should().Be(200);
        d["latency_ms"]!.GetValue<double>().Should().Be(123.4);
        d["model"]!.GetValue<string>().Should().Be("claude-3-5-sonnet");
        d["input_tokens"]!.GetValue<int>().Should().Be(10);
        d["output_tokens"]!.GetValue<int>().Should().Be(5);
    }

    [Fact]
    public void Tool_use_with_file_read_path_emits_file_read_event()
    {
        var convo = new Conversation { Provider = Provider.Anthropic };
        convo.Messages.Add(new Message(Role.Assistant, new Block[]
        {
            new Block.ToolUse("Read", """{"file_path":"/tmp/x"}"""),
        }));
        var captured = new List<(string Type, JsonObject Data)>();
        ConversationEventEmitter.Emit(
            Guid.NewGuid(), "api.anthropic.com", "/v1/messages", 200, 0,
            responseBody: null, convo,
            emit: (_, t, d) => captured.Add((t, d)));

        captured.Select(x => x.Type).Should().Equal(new[] { "llm.request", "tool.use", "file.read" });
        var fr = captured.Single(x => x.Type == "file.read").Data;
        fr["path"]!.GetValue<string>().Should().Be("/tmp/x");
        fr["tool"]!.GetValue<string>().Should().Be("Read");
    }

    [Fact]
    public void Bash_tool_emits_command_run_event()
    {
        var convo = new Conversation { Provider = Provider.Anthropic };
        convo.Messages.Add(new Message(Role.Assistant, new Block[]
        {
            new Block.ToolUse("Bash", """{"command":"git status"}"""),
        }));
        var captured = new List<(string Type, JsonObject Data)>();
        ConversationEventEmitter.Emit(
            Guid.NewGuid(), "api.anthropic.com", "/v1/messages", 200, 0,
            responseBody: null, convo,
            emit: (_, t, d) => captured.Add((t, d)));

        var cr = captured.Single(x => x.Type == "command.run").Data;
        cr["command"]!.GetValue<string>().Should().Be("git status");
    }

    [Fact]
    public void Older_assistant_turns_are_not_re_emitted()
    {
        // Two assistant turns in history — only the last one's tools
        // should be walked, otherwise multi-turn conversations
        // double-count older tool uses.
        var convo = new Conversation { Provider = Provider.Anthropic };
        convo.Messages.Add(new Message(Role.Assistant, new Block[]
        { new Block.ToolUse("Read", """{"file_path":"/old"}""") }));
        convo.Messages.Add(new Message(Role.User, new Block[] { new Block.Text("more") }));
        convo.Messages.Add(new Message(Role.Assistant, new Block[]
        { new Block.ToolUse("Read", """{"file_path":"/new"}""") }));

        var captured = new List<(string Type, JsonObject Data)>();
        ConversationEventEmitter.Emit(
            Guid.NewGuid(), "api.anthropic.com", "/v1/messages", 200, 0,
            null, convo, (_, t, d) => captured.Add((t, d)));

        captured.Where(x => x.Type == "file.read")
            .Select(x => x.Data["path"]!.GetValue<string>())
            .Should().Equal(new[] { "/new" });
    }
}
