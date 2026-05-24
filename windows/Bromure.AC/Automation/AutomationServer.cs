// macos-source: Sources/AgentCoding/AutomationServer.swift @ 5feff2fd78b5
using System.IO;
using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Bromure.AC.Automation;

/// <summary>
/// HTTP server exposing a JSON API for orchestrating Bromure Agentic
/// Coding from outside the process. Direct port of macOS
/// <c>ACAutomationServer</c>. Same endpoints; same wire format.
///
/// <para>Two consumers today:</para>
/// <list type="bullet">
///   <item><c>bromure-ac-mcp.exe</c> (the MCP CLI shim) — translates
///   JSON-RPC stdio into HTTP against this surface.</item>
///   <item>External test harnesses (parity with macOS's <c>ac-e2e.mjs</c>).</item>
/// </list>
///
/// <para>Bound to <c>127.0.0.1:9223</c> by default. Debug endpoints
/// (<c>/app/state</c>, <c>/sessions/{id}/exec</c>) are gated on the
/// <c>BROMURE_DEBUG_CLAUDE</c> env var, same as macOS.</para>
/// </summary>
public sealed class AutomationServer : IDisposable
{
    /// <summary>9223 — one off from the browser's 9222 so both apps run
    /// side-by-side during development without conflicting.</summary>
    public const ushort DefaultPort = 9223;

    private readonly HttpListener _listener;
    private readonly bool _debug;
    private CancellationTokenSource? _cts;
    private Task? _loop;

    public ushort Port { get; }
    public string BindAddress { get; }
    public bool DebugEnabled => _debug;

    public sealed record ProfileInfo(string Id, string Name, string Color, string Tool, string AuthMode, int McpServerCount);
    public sealed record SessionInfo(string ProfileId, string ProfileName, int WindowId, bool Visible);

    /// <summary>Callbacks plumbed by <see cref="App"/> at startup.</summary>
    public Func<IReadOnlyList<ProfileInfo>>? OnListProfiles { get; set; }
    public Func<IReadOnlyList<SessionInfo>>? OnListSessions { get; set; }
    public Func<string, Task<SessionInfo?>>? OnCreateSession { get; set; }
    public Func<string, Task<bool>>? OnDestroySession { get; set; }
    public Func<JsonObject>? OnGetAppState { get; set; }
    public Func<string, string?>? OnGetProfileJson { get; set; }
    public Func<string, string, bool>? OnSetProfileJson { get; set; }
    public Func<string, string, string?>? OnGetProfileSetting { get; set; }
    public Func<string, string, string, bool>? OnSetProfileSetting { get; set; }
    /// <summary>(profileOrSessionId, shellCmd) -> stdout/stderr. Wired to
    /// the in-guest cmd-server via AF_HYPERV. Debug-gated.</summary>
    public Func<string, string, Task<string>>? OnExecInSession { get; set; }

    public AutomationServer(ushort port = DefaultPort, string bindAddress = "127.0.0.1")
    {
        Port = port;
        BindAddress = bindAddress;
        _debug = !string.IsNullOrEmpty(Environment.GetEnvironmentVariable("BROMURE_DEBUG_CLAUDE"));
        _listener = new HttpListener();
        _listener.Prefixes.Add($"http://{bindAddress}:{port}/");
    }

    public void Start()
    {
        _cts = new CancellationTokenSource();
        _listener.Start();
        _loop = Task.Run(() => AcceptLoopAsync(_cts.Token));
    }

    public void Dispose()
    {
        try { _cts?.Cancel(); } catch { }
        try { _listener.Stop(); } catch { }
        try { _listener.Close(); } catch { }
        _cts?.Dispose();
    }

    private async Task AcceptLoopAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested && _listener.IsListening)
        {
            HttpListenerContext ctx;
            try { ctx = await _listener.GetContextAsync().ConfigureAwait(false); }
            catch (HttpListenerException) { return; }
            catch (ObjectDisposedException) { return; }
            _ = Task.Run(() => HandleRequestAsync(ctx, ct), ct);
        }
    }

    private async Task HandleRequestAsync(HttpListenerContext ctx, CancellationToken ct)
    {
        try
        {
            var path = ctx.Request.Url?.AbsolutePath ?? "/";
            var method = ctx.Request.HttpMethod;
            JsonObject body = await ReadBodyAsync(ctx.Request).ConfigureAwait(false);

            switch ((method, path))
            {
                case ("GET", "/health"):
                    Respond(ctx, 200, new JsonObject
                    {
                        ["status"] = "ok",
                        ["service"] = "bromure-ac-automation",
                        ["debugEnabled"] = _debug,
                    });
                    return;

                case ("GET", "/profiles"):
                    Respond(ctx, 200, new JsonObject
                    {
                        ["profiles"] = ToJsonArray(OnListProfiles?.Invoke() ?? Array.Empty<ProfileInfo>(), Profile2Json),
                    });
                    return;

                case ("GET", "/sessions"):
                    Respond(ctx, 200, new JsonObject
                    {
                        ["sessions"] = ToJsonArray(OnListSessions?.Invoke() ?? Array.Empty<SessionInfo>(), Session2Json),
                    });
                    return;

                case ("POST", "/sessions"):
                    var profile = body["profile"]?.GetValue<string>() ?? body["profileId"]?.GetValue<string>();
                    if (string.IsNullOrEmpty(profile))
                    {
                        Respond(ctx, 400, new JsonObject { ["error"] = "Missing 'profile' field" });
                        return;
                    }
                    var info = OnCreateSession is null ? null
                        : await OnCreateSession(profile).ConfigureAwait(false);
                    if (info is null) Respond(ctx, 500, new JsonObject { ["error"] = "Failed to create session" });
                    else Respond(ctx, 201, Session2Json(info));
                    return;

                case ("GET", "/app/state"):
                    if (!_debug) { Respond(ctx, 403, new JsonObject { ["error"] = "Debug endpoints require BROMURE_DEBUG_CLAUDE" }); return; }
                    var state = OnGetAppState?.Invoke() ?? new JsonObject();
                    state["debugEnabled"] = true;
                    Respond(ctx, 200, state);
                    return;
            }

            // /sessions/{id}, /sessions/{id}/exec
            if (path.StartsWith("/sessions/", StringComparison.Ordinal))
            {
                await HandleSessionSubpathAsync(ctx, method, path[10..], body).ConfigureAwait(false);
                return;
            }

            // /profiles/{id}/json, /profiles/{id}/settings/{key}
            if (path.StartsWith("/profiles/", StringComparison.Ordinal))
            {
                HandleProfileSubpath(ctx, method, path[10..], body);
                return;
            }

            Respond(ctx, 404, new JsonObject { ["error"] = "Not found", ["path"] = path });
        }
        catch (Exception ex)
        {
            try { Respond(ctx, 500, new JsonObject { ["error"] = ex.Message }); } catch { }
        }
    }

    private async Task HandleSessionSubpathAsync(HttpListenerContext ctx, string method, string rest, JsonObject body)
    {
        if (rest.EndsWith("/exec", StringComparison.Ordinal))
        {
            // Debug-gated shell exec. Pipes the request body through
            // GuestCommand → in-VM cmd-server → /bin/sh -c. Returns
            // collected stdout/stderr in `output`.
            if (!_debug) { Respond(ctx, 403, new JsonObject { ["error"] = "Debug endpoints require BROMURE_DEBUG_CLAUDE" }); return; }
            var sid = rest[..^"/exec".Length];
            var cmd = body["cmd"]?.GetValue<string>();
            if (string.IsNullOrEmpty(cmd))
            {
                Respond(ctx, 400, new JsonObject { ["error"] = "Missing 'cmd' field" });
                return;
            }
            if (OnExecInSession is null)
            {
                Respond(ctx, 503, new JsonObject { ["error"] = "Exec handler not wired" });
                return;
            }
            var output = await OnExecInSession(sid, cmd).ConfigureAwait(false);
            Respond(ctx, 200, new JsonObject { ["output"] = output });
            return;
        }

        if (rest.EndsWith("/read_file", StringComparison.Ordinal))
        {
            // Debug-gated. Reads <path> from inside the VM via cat
            // + base64, returns the decoded content in `content`.
            // Mirrors macOS Phase-2b's vm_read_file MCP tool.
            if (!_debug) { Respond(ctx, 403, new JsonObject { ["error"] = "Debug endpoints require BROMURE_DEBUG_CLAUDE" }); return; }
            var sid = rest[..^"/read_file".Length];
            var path = body["path"]?.GetValue<string>();
            if (string.IsNullOrEmpty(path)) { Respond(ctx, 400, new JsonObject { ["error"] = "Missing 'path' field" }); return; }
            if (OnExecInSession is null) { Respond(ctx, 503, new JsonObject { ["error"] = "Exec handler not wired" }); return; }
            // base64-encode the file in the guest so the output is
            // safe to round-trip through cmd-server's text channel
            // regardless of binary content. Failure path: cat exits
            // non-zero and base64 yields an empty string; we surface
            // the stderr in the response.
            //
            // Path is sent base64 to the guest then decoded into $p so
            // a malicious caller can't shell-inject via backticks /
            // $() / "" in the path (the cmd-server runs the line
            // through /bin/sh -c, which evaluates substitutions
            // inside double quotes). All base64 bytes are shell-safe.
            var pathB64 = Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes(path));
            var b64Cmd = $"sh -c 'p=$(printf %s \"{pathB64}\" | base64 -d); base64 -w 0 -- \"$p\" 2>&1 || true'";
            var b64 = (await OnExecInSession(sid, b64Cmd).ConfigureAwait(false)).Trim();
            byte[] bytes;
            try { bytes = Convert.FromBase64String(b64); }
            catch (FormatException)
            {
                Respond(ctx, 400, new JsonObject { ["error"] = "guest read failed", ["stderr"] = b64 });
                return;
            }
            Respond(ctx, 200, new JsonObject
            {
                ["path"] = path,
                ["content_base64"] = Convert.ToBase64String(bytes),
                ["size"] = bytes.Length,
            });
            return;
        }

        if (rest.EndsWith("/write_file", StringComparison.Ordinal))
        {
            // Debug-gated. Writes content to <path> inside the VM.
            // Content is supplied base64-encoded; the guest decodes
            // via `base64 -d > <path>`. Atomic-rename pattern: write
            // to <path>.tmp, then mv into place — same defensive
            // shape ProfileStore uses on the host.
            if (!_debug) { Respond(ctx, 403, new JsonObject { ["error"] = "Debug endpoints require BROMURE_DEBUG_CLAUDE" }); return; }
            var sid = rest[..^"/write_file".Length];
            var path = body["path"]?.GetValue<string>();
            var contentB64 = body["content_base64"]?.GetValue<string>();
            if (string.IsNullOrEmpty(path) || contentB64 is null)
            {
                Respond(ctx, 400, new JsonObject { ["error"] = "Missing 'path' or 'content_base64' field" });
                return;
            }
            if (OnExecInSession is null) { Respond(ctx, 503, new JsonObject { ["error"] = "Exec handler not wired" }); return; }
            // Sanity: contentB64 must be valid base64. Decode here so
            // a malformed request fails fast with a clear error
            // instead of "cat: invalid input" buried in stderr.
            try { _ = Convert.FromBase64String(contentB64); }
            catch (FormatException)
            {
                Respond(ctx, 400, new JsonObject { ["error"] = "'content_base64' is not valid base64" });
                return;
            }
            // Same injection-safe pattern as read_file above: path is
            // base64-encoded by the host, decoded inside single-quoted
            // shell so backticks / $() / "" in the path can't escape.
            var pathB64 = Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes(path));
            var writeCmd =
                $"sh -c 'p=$(printf %s \"{pathB64}\" | base64 -d); " +
                $"printf %s \"{contentB64}\" | base64 -d > \"$p.tmp\" && mv \"$p.tmp\" \"$p\" && echo OK'";
            var writeOut = (await OnExecInSession(sid, writeCmd).ConfigureAwait(false)).Trim();
            if (!writeOut.EndsWith("OK"))
            {
                Respond(ctx, 500, new JsonObject { ["error"] = "guest write failed", ["stderr"] = writeOut });
                return;
            }
            Respond(ctx, 200, new JsonObject { ["path"] = path, ["status"] = "ok" });
            return;
        }

        var id = rest;
        switch (method)
        {
            case "GET":
                var sessions = OnListSessions?.Invoke() ?? Array.Empty<SessionInfo>();
                var s = sessions.FirstOrDefault(x =>
                    string.Equals(x.ProfileId, id, StringComparison.OrdinalIgnoreCase)
                    || string.Equals(x.ProfileName, id, StringComparison.OrdinalIgnoreCase));
                if (s is null) Respond(ctx, 404, new JsonObject { ["error"] = "Session not found" });
                else Respond(ctx, 200, Session2Json(s));
                return;
            case "DELETE":
                var ok = OnDestroySession is null ? false
                    : await OnDestroySession(id).ConfigureAwait(false);
                Respond(ctx, ok ? 200 : 404,
                    new JsonObject { [ok ? "status" : "error"] = ok ? "closed" : "Session not found" });
                return;
            default:
                Respond(ctx, 405, new JsonObject { ["error"] = "Method not allowed" });
                return;
        }
    }

    private void HandleProfileSubpath(HttpListenerContext ctx, string method, string rest, JsonObject body)
    {
        var slash = rest.IndexOf('/');
        if (slash < 0)
        {
            Respond(ctx, 404, new JsonObject { ["error"] = "Not found" });
            return;
        }
        var id = rest[..slash];
        var sub = rest[(slash + 1)..];

        if (sub == "json")
        {
            switch (method)
            {
                case "GET":
                    var json = OnGetProfileJson?.Invoke(id);
                    if (json is null) Respond(ctx, 404, new JsonObject { ["error"] = "Profile not found" });
                    else RespondRaw(ctx, 200, json);
                    return;
                case "PUT":
                    var newJson = body["json"]?.GetValue<string>();
                    if (string.IsNullOrEmpty(newJson)) { Respond(ctx, 400, new JsonObject { ["error"] = "Missing 'json' field" }); return; }
                    var setOk = OnSetProfileJson?.Invoke(id, newJson) ?? false;
                    Respond(ctx, setOk ? 200 : 400,
                        new JsonObject { [setOk ? "status" : "error"] = setOk ? "ok" : "Update failed" });
                    return;
                default:
                    Respond(ctx, 405, new JsonObject { ["error"] = "Method not allowed" });
                    return;
            }
        }

        if (sub.StartsWith("settings/", StringComparison.Ordinal))
        {
            var key = sub[9..];
            switch (method)
            {
                case "GET":
                    var v = OnGetProfileSetting?.Invoke(id, key);
                    if (v is null) Respond(ctx, 404, new JsonObject { ["error"] = "Setting not found" });
                    else Respond(ctx, 200, new JsonObject { ["value"] = v });
                    return;
                case "PUT":
                    var newVal = body["value"]?.GetValue<string>();
                    if (newVal is null) { Respond(ctx, 400, new JsonObject { ["error"] = "Missing 'value' field" }); return; }
                    var setOk = OnSetProfileSetting?.Invoke(id, key, newVal) ?? false;
                    Respond(ctx, setOk ? 200 : 400,
                        new JsonObject { [setOk ? "status" : "error"] = setOk ? "ok" : "Update failed" });
                    return;
                default:
                    Respond(ctx, 405, new JsonObject { ["error"] = "Method not allowed" });
                    return;
            }
        }

        Respond(ctx, 404, new JsonObject { ["error"] = "Not found" });
    }

    // -- helpers --------------------------------------------------------

    private static async Task<JsonObject> ReadBodyAsync(HttpListenerRequest req)
    {
        if (req.ContentLength64 <= 0) return new JsonObject();
        using var reader = new StreamReader(req.InputStream, req.ContentEncoding ?? Encoding.UTF8);
        var text = await reader.ReadToEndAsync().ConfigureAwait(false);
        if (string.IsNullOrWhiteSpace(text)) return new JsonObject();
        try { return JsonNode.Parse(text) as JsonObject ?? new JsonObject(); }
        catch (JsonException) { return new JsonObject(); }
    }

    private static JsonObject Profile2Json(ProfileInfo p) => new()
    {
        ["id"] = p.Id,
        ["name"] = p.Name,
        ["color"] = p.Color,
        ["tool"] = p.Tool,
        ["authMode"] = p.AuthMode,
        ["mcpServerCount"] = p.McpServerCount,
    };

    private static JsonObject Session2Json(SessionInfo s) => new()
    {
        ["profileId"] = s.ProfileId,
        ["profileName"] = s.ProfileName,
        ["windowId"] = s.WindowId,
        ["visible"] = s.Visible,
    };

    private static JsonArray ToJsonArray<T>(IEnumerable<T> items, Func<T, JsonObject> map)
    {
        var arr = new JsonArray();
        foreach (var item in items) arr.Add(map(item));
        return arr;
    }

    // .NET 8 quirk: JsonNode writers with WriteIndented=true need a
    // non-null TypeInfoResolver, otherwise JsonValueCustomized<T> throws.
    private static readonly JsonSerializerOptions IndentedJson = new()
    {
        WriteIndented = true,
        TypeInfoResolver = new System.Text.Json.Serialization.Metadata.DefaultJsonTypeInfoResolver(),
    };

    private static void Respond(HttpListenerContext ctx, int status, JsonNode body)
    {
        var json = body.ToJsonString(IndentedJson);
        var bytes = Encoding.UTF8.GetBytes(json);
        ctx.Response.StatusCode = status;
        ctx.Response.ContentType = "application/json";
        ctx.Response.ContentLength64 = bytes.Length;
        try { ctx.Response.OutputStream.Write(bytes, 0, bytes.Length); } catch { }
        try { ctx.Response.OutputStream.Close(); } catch { }
    }

    private static void RespondRaw(HttpListenerContext ctx, int status, string text)
    {
        var bytes = Encoding.UTF8.GetBytes(text);
        ctx.Response.StatusCode = status;
        ctx.Response.ContentType = "application/json";
        ctx.Response.ContentLength64 = bytes.Length;
        try { ctx.Response.OutputStream.Write(bytes, 0, bytes.Length); } catch { }
        try { ctx.Response.OutputStream.Close(); } catch { }
    }
}
