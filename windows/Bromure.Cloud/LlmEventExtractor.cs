// macos-source: Sources/AgentCoding/LLMEventExtractor.swift @ fd23ee9e9675
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Bromure.Cloud;

/// <summary>
/// Direct port of <c>Sources/AgentCoding/LLMEventExtractor.swift</c>.
///
/// <para>Tool-name classification + token counter extraction. The
/// upstream conversation parser (Phase 5 follow-up) feeds parsed bodies
/// here; the host emits the resulting <c>llm.request</c> /
/// <c>tool.use</c> / <c>file.read</c> / <c>file.write</c> /
/// <c>command.run</c> events through the cloud uploader.</para>
///
/// <para><b>Privacy posture.</b> No raw prompts are emitted. Admin
/// telemetry is "what did the AI do" (paths, commands, token counts) —
/// never "what did the user ask". Credential-use events
/// (<c>token_swap</c>, <c>ssh_sign</c>, <c>aws_sign</c>) come from a
/// different code path so the audit trail exists even when the AI body
/// wasn't captured.</para>
/// </summary>
public static class LlmEventExtractor
{
    public sealed record TokenCounters(
        int? InputTokens = null,
        int? OutputTokens = null,
        int? CacheCreationInputTokens = null,
        int? CacheReadInputTokens = null);

    public enum Provider { Anthropic, OpenAi, Google, Other }

    /// <summary>Read-the-file-system tools across providers / agent SDKs.</summary>
    public static bool IsFileReadTool(string name) => name switch
    {
        "Read" or "ReadFile" or "view" or "View"
            or "read_file" or "list_dir" or "ls" or "LS"
            or "Glob" or "glob" or "Grep" or "grep"
            or "str_replace_editor" => true,
        _ => false,
    };

    public static bool IsFileWriteTool(string name) => name switch
    {
        "Write" or "WriteFile" or "Edit" or "MultiEdit" or "NotebookEdit"
            or "create" or "Create" or "str_replace"
            or "write_file" or "apply_patch" or "edit_file" => true,
        _ => false,
    };

    public static bool IsCommandTool(string name) => name switch
    {
        "Bash" or "Shell" or "shell" or "Run" or "RunCommand"
            or "exec" or "execute" or "exec_command" or "run_command"
            or "container.exec" => true,
        _ => false,
    };

    /// <summary>Pull a file path out of a tool input JSON, regardless of provider key naming.</summary>
    public static string? ExtractPath(string toolInput)
    {
        var obj = ParseInputJson(toolInput);
        if (obj is null) return null;
        foreach (var key in new[] { "file_path", "path", "filename", "target_file" })
        {
            if (obj[key]?.GetValue<string>() is { Length: > 0 } v) return v;
        }
        return null;
    }

    public static string? ExtractCommand(string toolInput)
    {
        var obj = ParseInputJson(toolInput);
        if (obj is null) return null;
        foreach (var key in new[] { "command", "cmd", "script" })
        {
            var node = obj[key];
            if (node is null) continue;
            // Codex `shell` passes command as ["bash","-lc","<cmd>"].
            if (node is JsonArray arr)
            {
                var strs = new List<string>();
                foreach (var n in arr)
                {
                    if (n is JsonValue v && v.TryGetValue<string>(out var s) && s is not null)
                    {
                        strs.Add(s);
                    }
                }
                if (strs.Count >= 3
                    && new[] { "bash", "/bin/bash", "sh", "/bin/sh", "zsh" }.Contains(strs[0])
                    && strs[1].StartsWith("-", StringComparison.Ordinal))
                {
                    return Summarize(strs[2], 500);
                }
                var joined = string.Join(' ', strs);
                if (joined.Length > 0) return Summarize(joined, 500);
                continue;
            }
            if (node is JsonValue jv && jv.TryGetValue<string>(out var str) && !string.IsNullOrEmpty(str))
            {
                return Summarize(str, 500);
            }
        }
        return null;
    }

    private static JsonObject? ParseInputJson(string input)
    {
        try { return JsonNode.Parse(input) as JsonObject; }
        catch (JsonException) { return null; }
    }

    private static string Summarize(string input, int max)
        => input.Length <= max ? input : input[..max] + "…";

    /// <summary>Parse Anthropic's usage block (non-streaming + SSE).</summary>
    public static TokenCounters ParseAnthropicTokens(byte[] body)
    {
        var (top, sse) = TopLevelOrSseUsage(body);
        if (top is { } u)
        {
            return new TokenCounters(
                u["input_tokens"]?.GetValue<int?>(),
                u["output_tokens"]?.GetValue<int?>(),
                u["cache_creation_input_tokens"]?.GetValue<int?>(),
                u["cache_read_input_tokens"]?.GetValue<int?>());
        }
        // SSE: walk lines, pick highest output_tokens.
        int? input = null, output = null, cacheCreate = null, cacheRead = null;
        foreach (var line in sse)
        {
            if (line["message"]?["usage"] is JsonObject mu)
            {
                input = mu["input_tokens"]?.GetValue<int?>() ?? input;
                cacheCreate = mu["cache_creation_input_tokens"]?.GetValue<int?>() ?? cacheCreate;
                cacheRead = mu["cache_read_input_tokens"]?.GetValue<int?>() ?? cacheRead;
                if (mu["output_tokens"]?.GetValue<int?>() is { } o) output = o;
            }
            if (line["usage"] is JsonObject uu)
            {
                if (uu["output_tokens"]?.GetValue<int?>() is { } o) output = o;
            }
        }
        return new TokenCounters(input, output, cacheCreate, cacheRead);
    }

    public static TokenCounters ParseOpenAiTokens(byte[] body)
    {
        var (top, _) = TopLevelOrSseUsage(body);
        if (top is null) return new TokenCounters();
        var input = top["prompt_tokens"]?.GetValue<int?>();
        var output = top["completion_tokens"]?.GetValue<int?>();
        int? cacheRead = null;
        if (top["prompt_tokens_details"] is JsonObject details)
        {
            cacheRead = details["cached_tokens"]?.GetValue<int?>();
        }
        return new TokenCounters(input, output, null, cacheRead);
    }

    private static (JsonObject? top, IEnumerable<JsonObject> sse) TopLevelOrSseUsage(byte[] body)
    {
        try
        {
            if (JsonNode.Parse(body) is JsonObject root && root["usage"] is JsonObject usage)
            {
                return (usage, Array.Empty<JsonObject>());
            }
        }
        catch (JsonException) { /* fall through to SSE */ }

        var lines = new List<JsonObject>();
        var text = System.Text.Encoding.UTF8.GetString(body);
        foreach (var raw in text.Split('\n'))
        {
            var line = raw.Trim();
            if (!line.StartsWith("data:", StringComparison.Ordinal)) continue;
            var json = line["data:".Length..].Trim();
            try
            {
                if (JsonNode.Parse(json) is JsonObject obj) lines.Add(obj);
            }
            catch (JsonException) { /* skip */ }
        }
        return (null, lines);
    }
}
