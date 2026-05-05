using System.Text.Json;
using System.Text.Json.Nodes;

namespace Bromure.Cloud;

/// <summary>
/// Direct port of <c>BACCloudEvent</c> from
/// <c>Sources/AgentCoding/CloudEvents.swift</c>. Wire shape matches the
/// server's <c>POST /v1/installs/:installId/ac-events</c>.
/// </summary>
public sealed record CloudEvent(
    Guid SessionId,
    Guid? ProfileId,
    DateTimeOffset Ts,
    string EventType,
    JsonObject EventData)
{
    public static JsonObject DataFrom(IEnumerable<KeyValuePair<string, object?>> kvs)
    {
        var obj = new JsonObject();
        foreach (var (k, v) in kvs)
        {
            obj[k] = v switch
            {
                null => null,
                string s => JsonValue.Create(s),
                int i => JsonValue.Create(i),
                long l => JsonValue.Create(l),
                double d => JsonValue.Create(d),
                bool b => JsonValue.Create(b),
                _ => JsonValue.Create(JsonSerializer.Serialize(v)),
            };
        }
        return obj;
    }
}
