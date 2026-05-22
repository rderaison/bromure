// macos-source: Sources/AgentCoding/Mitm/RealtimeEventTap.swift @ af5926be7128
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.Extensions.Logging;

namespace Bromure.AC.Mitm.WebSocket;

/// <summary>
/// Streaming event extractor for OpenAI Realtime / Codex WebSocket
/// sessions. Attached as the upstream→client message hook on a
/// <see cref="WsMessageAssembler"/>, watches every assembled text
/// frame and counts <c>response.completed</c> events.
///
/// <para>One instance per WebSocket connection. <see cref="StreamedAnyEvents"/>
/// lets the caller decide whether to skip a close-time
/// <c>LlmEventExtractor</c> emission so the final assistant turn
/// isn't double-counted.</para>
///
/// <para>Slim port: the macOS version pushes parsed events through
/// <c>BACEventEmitter</c> for the trace inspector. Windows currently
/// just logs + counts; cloud-event emission is a follow-up that needs
/// the LlmEventExtractor wiring to land first.</para>
/// </summary>
public sealed class RealtimeEventTap
{
    public Guid ProfileId { get; }
    public string Host { get; }
    public string Path { get; }
    public int StatusCode { get; }

    private readonly ILogger _log;
    private readonly Action<Guid, string, JsonObject>? _onCloudEvent;
    private readonly object _gate = new();
    private int _streamedResponseCount;

    public RealtimeEventTap(Guid profileId, string host, string path, int statusCode,
        ILogger? log = null,
        Action<Guid, string, JsonObject>? onCloudEvent = null)
    {
        ProfileId = profileId;
        Host = host;
        Path = path;
        StatusCode = statusCode;
        _log = log ?? Microsoft.Extensions.Logging.Abstractions.NullLogger.Instance;
        _onCloudEvent = onCloudEvent;
    }

    /// <summary>True once any <c>response.completed</c> has been streamed.
    /// Read by the caller to gate the close-time LLM event emit.</summary>
    public bool StreamedAnyEvents
    {
        get { lock (_gate) return _streamedResponseCount > 0; }
    }

    public int StreamedResponseCount
    {
        get { lock (_gate) return _streamedResponseCount; }
    }

    /// <summary>
    /// Inspect one assembled WebSocket message. Only TEXT messages
    /// carrying a JSON object with <c>type == "response.completed"</c>
    /// are counted; everything else is ignored.
    /// </summary>
    public void Handle(WsMessageAssembler.Message msg)
    {
        if (msg.Kind != WsMessageAssembler.MessageKind.Text) return;
        if (msg.Payload.Length == 0) return;

        JsonNode? root;
        try { root = JsonNode.Parse(msg.Payload); }
        catch (JsonException) { return; }
        if (root is not JsonObject obj) return;
        var type = obj["type"]?.GetValue<string>();
        if (type != "response.completed") return;
        var response = obj["response"] as JsonObject;
        if (response is null) return;

        var model = response["model"]?.GetValue<string>();
        var respId = response["id"]?.GetValue<string>();
        int? inputTokens = null, outputTokens = null;
        if (response["usage"] is JsonObject usage)
        {
            if (usage["input_tokens"] is JsonValue iv && iv.TryGetValue<int>(out var it)) inputTokens = it;
            if (usage["output_tokens"] is JsonValue ov && ov.TryGetValue<int>(out var ot)) outputTokens = ot;
        }

        lock (_gate) _streamedResponseCount++;
        _log.LogDebug(
            "ws-realtime response.completed host={Host} model={Model} input_tokens={InputTokens} output_tokens={OutputTokens} response_id={ResponseId}",
            Host, model ?? "?", inputTokens?.ToString() ?? "?",
            outputTokens?.ToString() ?? "?", respId ?? "?");

        // Emit a cloud audit event so realtime streaming sessions
        // show up in the dashboard incrementally — the close-time
        // LlmEventExtractor wouldn't see streamed responses since
        // there's no buffered body. Direct port of macOS
        // RealtimeEventTap.swift:69-72.
        if (_onCloudEvent is not null)
        {
            try
            {
                var data = new JsonObject
                {
                    ["host"] = Host,
                    ["path"] = Path,
                    ["model"] = model,
                    ["response_id"] = respId,
                    ["input_tokens"] = inputTokens,
                    ["output_tokens"] = outputTokens,
                    ["status_code"] = StatusCode,
                };
                _onCloudEvent(ProfileId, "llm.request", data);
            }
            catch (Exception ex)
            {
                _log.LogDebug(ex, "RealtimeEventTap cloud-event emission threw");
            }
        }
    }

    /// <summary>
    /// Hosts that serve OpenAI's Realtime / Codex WebSocket API.
    /// Used by the proxy to gate when a tap gets attached — for
    /// every other WS upgrade the tap would just sit idle.
    /// </summary>
    public static bool ShouldTap(string host)
    {
        var h = host.ToLowerInvariant();
        return h == "api.openai.com" || h.EndsWith(".openai.com")
            || h == "chatgpt.com" || h.EndsWith(".chatgpt.com");
    }
}
