// macos-source: Sources/AgentCoding/ConversationView.swift @ 18a8f5638b0f
namespace Bromure.AC.Mitm.Conversation;

/// <summary>
/// Structured view of one LLM exchange, parsed from raw HTTP request +
/// response bodies. Direct port of the Swift <c>Conversation</c> struct
/// from <c>ConversationView.swift</c>; consumed by the inspector and by
/// <c>LlmEventExtractor</c> for cloud audit events.
/// </summary>
public sealed class Conversation
{
    public Provider Provider { get; set; } = Provider.Unknown;
    public string? Model { get; set; }
    public string? SystemPrompt { get; set; }
    public List<Message> Messages { get; set; } = new();
    public int? InputTokens { get; set; }
    public int? OutputTokens { get; set; }
    /// <summary>True when the parser fell back to a non-canonical body shape.</summary>
    public bool Raw { get; set; }
    /// <summary>Pretty-printed JSON of the original request envelope —
    /// surfaced as a collapsible bubble in the inspector so the user
    /// can audit fields the parser didn't promote.</summary>
    public string? RequestEnvelope { get; set; }
}

public enum Provider { Anthropic, OpenAi, Gemini, Cohere, Unknown }

public sealed class Message
{
    public Guid Id { get; } = Guid.NewGuid();
    public Role Role { get; set; }
    public List<Block> Content { get; set; } = new();

    public Message(Role role, IEnumerable<Block>? content = null)
    {
        Role = role;
        if (content is not null) Content.AddRange(content);
    }
}

public enum Role { System, User, Assistant, Tool }

/// <summary>One element of a message body. Discriminated union: text,
/// tool_use, tool_result, image. Matches the Anthropic Messages API
/// shape and is also produced by the OpenAI parser.</summary>
public abstract class Block
{
    public sealed class Text : Block
    {
        public string Value { get; }
        public Text(string value) => Value = value;
    }

    public sealed class ToolUse : Block
    {
        public string Name { get; }
        /// <summary>JSON-encoded input map (pretty-printed, keys sorted).</summary>
        public string Input { get; }
        public ToolUse(string name, string input) { Name = name; Input = input; }
    }

    public sealed class ToolResult : Block
    {
        public string? ToolUseId { get; }
        public string Content { get; }
        public bool IsError { get; }
        public ToolResult(string? toolUseId, string content, bool isError)
        {
            ToolUseId = toolUseId; Content = content; IsError = isError;
        }
    }

    public sealed class Image : Block
    {
        public string MediaType { get; }
        public Image(string mediaType) => MediaType = mediaType;
    }
}
