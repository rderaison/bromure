// macos-source: Sources/AgentCoding/LLMEventExtractor.swift @ fd23ee9e9675
using System.Text.Json.Nodes;
using Bromure.Cloud;

namespace Bromure.AC.Mitm.Conversation;

/// <summary>
/// Orchestrator that walks a parsed <see cref="Conversation"/> and pushes
/// <c>llm.request</c>, <c>tool.use</c>, <c>file.read</c>,
/// <c>file.write</c>, and <c>command.run</c> events through a caller-
/// provided sink. Mirrors <c>LLMEventExtractor.emit</c> in the Swift
/// source. Tool-name classification + token-counter parsing live in
/// <see cref="LlmEventExtractor"/> so the helpers remain reusable from
/// other capture sites.
/// </summary>
public static class ConversationEventEmitter
{
    /// <summary>
    /// Emit one exchange's worth of cloud events.
    /// </summary>
    /// <param name="profileId">Profile owning the session.</param>
    /// <param name="host">Upstream host (apex, no port).</param>
    /// <param name="path">Request path (no query) for the audit row.</param>
    /// <param name="statusCode">HTTP status from the upstream response.</param>
    /// <param name="latencyMs">Connect-to-response wall time in ms.</param>
    /// <param name="responseBody">Raw response body for token re-parse —
    /// may be null when the response was streamed and discarded.</param>
    /// <param name="conversation">The parsed exchange.</param>
    /// <param name="emit">Sink — receives <c>(profileId, eventType, data)</c>.</param>
    public static void Emit(
        Guid profileId,
        string host,
        string path,
        int statusCode,
        double latencyMs,
        byte[]? responseBody,
        Conversation conversation,
        Action<Guid, string, JsonObject> emit)
    {
        var tokens = ParseTokenCounters(conversation.Provider, responseBody);

        // llm.request — one per exchange.
        var llmData = new JsonObject
        {
            ["provider"]    = ProviderToWire(conversation.Provider),
            ["host"]        = host,
            ["path"]        = path,
            ["status_code"] = statusCode,
            ["latency_ms"]  = latencyMs,
        };
        if (conversation.Model is { Length: > 0 } m) llmData["model"] = m;
        if ((tokens.InputTokens ?? conversation.InputTokens) is { } it)   llmData["input_tokens"] = it;
        if ((tokens.OutputTokens ?? conversation.OutputTokens) is { } ot) llmData["output_tokens"] = ot;
        if (tokens.CacheCreationInputTokens is { } cc) llmData["cache_creation_input_tokens"] = cc;
        if (tokens.CacheReadInputTokens is { } cr)     llmData["cache_read_input_tokens"] = cr;
        emit(profileId, "llm.request", llmData);

        // Walk the most recent assistant turn for tool calls. Older turns
        // are echoed back on every subsequent request, so emitting them
        // would double-count.
        var assistant = conversation.Messages.LastOrDefault(m => m.Role == Role.Assistant);
        if (assistant is null) return;

        foreach (var block in assistant.Content)
        {
            if (block is not Block.ToolUse tu) continue;

            // Generic envelope first — drives the "tools" insights view
            // that doesn't care about file-vs-command specifics.
            emit(profileId, "tool.use", new JsonObject
            {
                ["tool_name"] = tu.Name,
                ["input_summary"] = SummarizeForTrace(tu.Input, 240),
            });

            if (LlmEventExtractor.IsFileReadTool(tu.Name))
            {
                if (LlmEventExtractor.ExtractPath(tu.Input) is { Length: > 0 } p)
                {
                    emit(profileId, "file.read", new JsonObject
                    { ["path"] = p, ["tool"] = tu.Name });
                }
            }
            else if (LlmEventExtractor.IsFileWriteTool(tu.Name))
            {
                if (LlmEventExtractor.ExtractPath(tu.Input) is { Length: > 0 } p)
                {
                    emit(profileId, "file.write", new JsonObject
                    { ["path"] = p, ["tool"] = tu.Name });
                }
            }
            else if (LlmEventExtractor.IsCommandTool(tu.Name))
            {
                if (LlmEventExtractor.ExtractCommand(tu.Input) is { Length: > 0 } cmd)
                {
                    emit(profileId, "command.run", new JsonObject
                    { ["command"] = cmd, ["tool"] = tu.Name });
                }
            }
        }
    }

    private static LlmEventExtractor.TokenCounters ParseTokenCounters(
        Provider provider, byte[]? body)
    {
        if (body is null || body.Length == 0) return new LlmEventExtractor.TokenCounters();
        return provider switch
        {
            Provider.Anthropic => LlmEventExtractor.ParseAnthropicTokens(body),
            Provider.OpenAi    => LlmEventExtractor.ParseOpenAiTokens(body),
            _                  => new LlmEventExtractor.TokenCounters(),
        };
    }

    private static string ProviderToWire(Provider p) => p switch
    {
        Provider.Anthropic => "anthropic",
        Provider.OpenAi    => "openai",
        Provider.Gemini    => "gemini",
        Provider.Cohere    => "cohere",
        _                  => "unknown",
    };

    private static string SummarizeForTrace(string input, int max)
        => input.Length <= max ? input : input[..max] + "…";
}
