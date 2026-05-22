// macos-source: Sources/AgentCoding/MCPServer.swift @ 5feff2fd78b5
//
// JSON-RPC stdio MCP server for Bromure AC. Translates MCP tool calls
// into HTTP requests against the AC app's automation server
// (127.0.0.1:9223). Mirrors the macOS `bromure-ac mcp` subcommand.
//
// Wire format: line-delimited JSON, one JSON-RPC message per line on
// stdin/stdout. Errors written to stderr (the agent surfaces them in
// its MCP debug pane).

using System.Net.Http.Json;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Bromure.AC.Mcp;

internal static class Program
{
    private const string DefaultApiUrl = "http://127.0.0.1:9223";

    private static bool _debug;
    private static string _apiBase = DefaultApiUrl;
    private static readonly HttpClient Http = new();

    private static async Task<int> Main(string[] args)
    {
        // Tiny ad-hoc arg parser — matches `bromure-ac mcp --debug --api-url URL`.
        for (var i = 0; i < args.Length; i++)
        {
            switch (args[i])
            {
                case "--debug": _debug = true; break;
                case "--api-url":
                    if (i + 1 < args.Length) _apiBase = args[++i];
                    break;
                case "-h":
                case "--help":
                    Console.Error.WriteLine("usage: bromure-ac-mcp [--debug] [--api-url http://127.0.0.1:9223]");
                    return 0;
            }
        }

        Http.BaseAddress = new Uri(_apiBase);

        string? line;
        while ((line = await Console.In.ReadLineAsync().ConfigureAwait(false)) is not null)
        {
            line = line.Trim();
            if (line.Length == 0) continue;

            JsonObject? msg;
            try { msg = JsonNode.Parse(line) as JsonObject; }
            catch (JsonException) { continue; }
            if (msg is null) continue;

            var id = msg["id"];
            var method = (string?)msg["method"] ?? "";
            var pars = msg["params"] as JsonObject ?? new JsonObject();

            try
            {
                switch (method)
                {
                    case "initialize":
                        Respond(id, new JsonObject
                        {
                            ["protocolVersion"] = "2025-03-26",
                            ["serverInfo"] = new JsonObject
                            {
                                ["name"] = "bromure-ac",
                                ["version"] = "1.0.0",
                            },
                            ["capabilities"] = new JsonObject
                            {
                                ["tools"] = new JsonObject { ["listChanged"] = false },
                            },
                        });
                        break;
                    case "notifications/initialized":
                    case "notifications/cancelled":
                        break;
                    case "ping":
                        Respond(id, new JsonObject());
                        break;
                    case "tools/list":
                        Respond(id, new JsonObject { ["tools"] = ToolDefinitions() });
                        break;
                    case "tools/call":
                        var toolName = (string?)pars["name"] ?? "";
                        var toolArgs = pars["arguments"] as JsonObject ?? new JsonObject();
                        var result = await CallToolAsync(toolName, toolArgs).ConfigureAwait(false);
                        Respond(id, result);
                        break;
                    default:
                        RespondError(id, -32601, $"Method not found: {method}");
                        break;
                }
            }
            catch (Exception ex)
            {
                RespondError(id, -32000, ex.Message);
            }
        }
        return 0;
    }

    // -- Tool catalog ---------------------------------------------------

    private static JsonArray ToolDefinitions()
    {
        var tools = new JsonArray
        {
            Tool("bromure_ac_list_profiles",
                "List all AC profiles with their id, name, color, tool, authMode, and MCP-server count.",
                new JsonObject()),
            Tool("bromure_ac_list_sessions",
                "List currently-open AC session windows.",
                new JsonObject()),
            Tool("bromure_ac_open_session",
                "Launch the session window for a profile. Returns when the window is visible (or after a 30s timeout).",
                new JsonObject { ["profile"] = Prop("string", "Profile name or UUID", true) }),
            Tool("bromure_ac_close_session",
                "Close any open session window for the given profile.",
                new JsonObject { ["profile"] = Prop("string", "Profile name or UUID", true) }),
            Tool("bromure_ac_get_profile",
                "Return the full Profile (including nested credentials, MCP servers, etc.) as JSON.",
                new JsonObject { ["profile"] = Prop("string", "Profile name or UUID", true) }),
            Tool("bromure_ac_set_profile",
                "Replace a profile atomically from a JSON blob. The profile's id is preserved.",
                new JsonObject
                {
                    ["profile"] = Prop("string", "Profile name or UUID", true),
                    ["json"] = Prop("string", "JSON-encoded Profile", true),
                }),
            Tool("bromure_ac_get_profile_setting",
                "Read one simple profile field. Identity: name, comments, color, createdAt, lastUsedAt, baseImageVersionAtClone. " +
                "Tool/auth: tool, authMode, apiKey, apiKeyRequiresApproval. " +
                "Cosmetic: useTerminalAppDefaults, customFontFamily, customFontSize, customBackgroundHex, customForegroundHex, cursorShape, windowOpacity, keyboardLayoutOverride, keyRepeatDelayMs, keyRepeatRateHz. " +
                "VM: memoryGB, networkMode, bridgedInterfaceID, closeAction. " +
                "Git: gitUserName, gitUserEmail. " +
                "SSH: sshKeyRequiresApproval, sshPublicKey. " +
                "Misc: digitalOceanToken, digitalOceanRequiresApproval, bedrockEnabled, bedrockModelID, subscriptionTokenSwap, codexTokenSwap. " +
                "Privacy/tracing: privateMode, traceLevel. " +
                "Counts: folderPathsCount, mcpServerCount.",
                new JsonObject
                {
                    ["profile"] = Prop("string", "Profile name or UUID", true),
                    ["key"] = Prop("string", "Setting key", true),
                }),
            Tool("bromure_ac_set_profile_setting",
                "Write one simple profile field. See bromure_ac_get_profile_setting for the supported keys.",
                new JsonObject
                {
                    ["profile"] = Prop("string", "Profile name or UUID", true),
                    ["key"] = Prop("string", "Setting key", true),
                    ["value"] = Prop("string", "New value (as text)", true),
                }),
        };
        if (_debug)
        {
            tools.Add(Tool("bromure_ac_app_state",
                "Debug: full app-state snapshot (phase, window visibility, profile/session counts, hasBaseImage).",
                new JsonObject()));
            tools.Add(Tool("bromure_ac_vm_exec",
                "Debug: run a /bin/sh -c command inside the running VM for a profile. Returns combined stdout+stderr.",
                new JsonObject
                {
                    ["profile"] = Prop("string", "Profile name or UUID", true),
                    ["cmd"] = Prop("string", "Shell command to run", true),
                }));
            tools.Add(Tool("bromure_ac_vm_read_file",
                "Debug: read a file from inside the VM. Returns base64-encoded content + size.",
                new JsonObject
                {
                    ["profile"] = Prop("string", "Profile name or UUID", true),
                    ["path"] = Prop("string", "Absolute path inside the VM", true),
                }));
            tools.Add(Tool("bromure_ac_vm_write_file",
                "Debug: write a file inside the VM (atomic rename via .tmp). Content is base64-encoded.",
                new JsonObject
                {
                    ["profile"] = Prop("string", "Profile name or UUID", true),
                    ["path"] = Prop("string", "Absolute path inside the VM", true),
                    ["content_base64"] = Prop("string", "File content, base64-encoded", true),
                }));
            tools.Add(Tool("bromure_ac_vm_screenshot",
                "Debug: capture the current kitty terminal contents (text) from inside the VM. Useful for asserting tool output during automated workflows.",
                new JsonObject
                {
                    ["profile"] = Prop("string", "Profile name or UUID", true),
                    ["extent"] = Prop("string",
                        "Capture extent: 'screen' (visible), 'all' (incl. scrollback), 'last_cmd_output' (just the most recent command). Defaults to 'screen'.",
                        false),
                }));
        }
        return tools;
    }

    private static JsonObject Tool(string name, string desc, JsonObject props)
    {
        var required = new JsonArray();
        var cleanProps = new JsonObject();
        foreach (var (k, v) in props)
        {
            if (v is JsonObject obj && obj["_required"]?.GetValue<bool>() == true)
            {
                required.Add(k);
                obj.Remove("_required");
            }
            cleanProps[k] = v?.DeepClone();
        }
        var schema = new JsonObject { ["type"] = "object", ["properties"] = cleanProps };
        if (required.Count > 0) schema["required"] = required;
        return new JsonObject { ["name"] = name, ["description"] = desc, ["inputSchema"] = schema };
    }

    private static JsonObject Prop(string type, string desc, bool required = false)
    {
        var p = new JsonObject { ["type"] = type, ["description"] = desc };
        if (required) p["_required"] = true;
        return p;
    }

    // -- Tool dispatch --------------------------------------------------

    private static async Task<JsonObject> CallToolAsync(string name, JsonObject args)
    {
        try
        {
            return await DispatchAsync(name, args).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            return ErrorResult(ex.Message);
        }
    }

    private static async Task<JsonObject> DispatchAsync(string name, JsonObject args)
    {
        switch (name)
        {
            case "bromure_ac_list_profiles":
                return TextResult(JsonString((await ApiCall("GET", "/profiles").ConfigureAwait(false))["profiles"]));
            case "bromure_ac_list_sessions":
                return TextResult(JsonString((await ApiCall("GET", "/sessions").ConfigureAwait(false))["sessions"]));
            case "bromure_ac_open_session":
                var profile = RequireArg(args, "profile");
                var open = await ApiCall("POST", "/sessions", new JsonObject { ["profile"] = profile }).ConfigureAwait(false);
                if (open["error"] is JsonNode err) throw new InvalidOperationException(err.GetValue<string>());
                return TextResult(JsonString(open));
            case "bromure_ac_close_session":
                var closeNameOrId = RequireArg(args, "profile");
                // The DELETE /sessions/{id} endpoint accepts either a UUID
                // or a profile name (the server-side handler resolves).
                var closed = await ApiCall("DELETE", $"/sessions/{Uri.EscapeDataString(closeNameOrId)}").ConfigureAwait(false);
                return TextResult(JsonString(closed));
            case "bromure_ac_get_profile":
                var pid = RequireArg(args, "profile");
                var pidResolved = await ResolveProfileIdAsync(pid).ConfigureAwait(false);
                var json = await Http.GetStringAsync($"/profiles/{Uri.EscapeDataString(pidResolved)}/json").ConfigureAwait(false);
                return TextResult(json);
            case "bromure_ac_set_profile":
                var spid = await ResolveProfileIdAsync(RequireArg(args, "profile")).ConfigureAwait(false);
                var newJson = RequireArg(args, "json");
                var setResp = await ApiCallPut($"/profiles/{Uri.EscapeDataString(spid)}/json",
                    new JsonObject { ["json"] = newJson }).ConfigureAwait(false);
                if (setResp["error"] is JsonNode serr) throw new InvalidOperationException(serr.GetValue<string>());
                return TextResult("ok");
            case "bromure_ac_get_profile_setting":
                var gpid = await ResolveProfileIdAsync(RequireArg(args, "profile")).ConfigureAwait(false);
                var key = RequireArg(args, "key");
                var setRead = await ApiCall("GET", $"/profiles/{Uri.EscapeDataString(gpid)}/settings/{Uri.EscapeDataString(key)}").ConfigureAwait(false);
                return TextResult((string?)setRead["value"] ?? "");
            case "bromure_ac_set_profile_setting":
                var spid2 = await ResolveProfileIdAsync(RequireArg(args, "profile")).ConfigureAwait(false);
                var key2 = RequireArg(args, "key");
                var val = RequireArg(args, "value");
                var setW = await ApiCallPut($"/profiles/{Uri.EscapeDataString(spid2)}/settings/{Uri.EscapeDataString(key2)}",
                    new JsonObject { ["value"] = val }).ConfigureAwait(false);
                if (setW["error"] is JsonNode wErr) throw new InvalidOperationException(wErr.GetValue<string>());
                return TextResult("ok");
            case "bromure_ac_app_state" when _debug:
                return TextResult(JsonString(await ApiCall("GET", "/app/state").ConfigureAwait(false)));
            case "bromure_ac_vm_exec" when _debug:
                var vmExecId = await ResolveProfileIdAsync(RequireArg(args, "profile")).ConfigureAwait(false);
                var vmCmd = RequireArg(args, "cmd");
                var vmRes = await ApiCall("POST", $"/sessions/{Uri.EscapeDataString(vmExecId)}/exec",
                    new JsonObject { ["cmd"] = vmCmd }).ConfigureAwait(false);
                if (vmRes["error"] is JsonNode vmErr) throw new InvalidOperationException(vmErr.GetValue<string>());
                return TextResult((string?)vmRes["output"] ?? "");
            case "bromure_ac_vm_read_file" when _debug:
                var rdId = await ResolveProfileIdAsync(RequireArg(args, "profile")).ConfigureAwait(false);
                var rdPath = RequireArg(args, "path");
                var rdRes = await ApiCall("POST", $"/sessions/{Uri.EscapeDataString(rdId)}/read_file",
                    new JsonObject { ["path"] = rdPath }).ConfigureAwait(false);
                if (rdRes["error"] is JsonNode rdErr) throw new InvalidOperationException(rdErr.GetValue<string>());
                return TextResult(JsonString(rdRes));
            case "bromure_ac_vm_screenshot" when _debug:
                var shotId = await ResolveProfileIdAsync(RequireArg(args, "profile")).ConfigureAwait(false);
                var extent = (string?)args["extent"] ?? "screen";
                // Map our friendly enum to kitty's --extent flag values.
                var kittyExtent = extent switch
                {
                    "all" => "all",
                    "last_cmd_output" => "last_cmd_output",
                    _ => "screen",
                };
                var kittyCmd = $"kitty @ --to=unix:@bromure-kitty get-text --extent={kittyExtent}";
                var shotRes = await ApiCall("POST", $"/sessions/{Uri.EscapeDataString(shotId)}/exec",
                    new JsonObject { ["cmd"] = kittyCmd }).ConfigureAwait(false);
                if (shotRes["error"] is JsonNode shotErr) throw new InvalidOperationException(shotErr.GetValue<string>());
                return TextResult((string?)shotRes["output"] ?? "");
            case "bromure_ac_vm_write_file" when _debug:
                var wrId = await ResolveProfileIdAsync(RequireArg(args, "profile")).ConfigureAwait(false);
                var wrPath = RequireArg(args, "path");
                var wrContent = RequireArg(args, "content_base64");
                var wrRes = await ApiCall("POST", $"/sessions/{Uri.EscapeDataString(wrId)}/write_file",
                    new JsonObject { ["path"] = wrPath, ["content_base64"] = wrContent }).ConfigureAwait(false);
                if (wrRes["error"] is JsonNode wrErr) throw new InvalidOperationException(wrErr.GetValue<string>());
                return TextResult("ok");
            default:
                throw new InvalidOperationException($"Unknown tool: {name}");
        }
    }

    private static async Task<string> ResolveProfileIdAsync(string nameOrId)
    {
        if (Guid.TryParse(nameOrId, out _)) return nameOrId;
        var list = await ApiCall("GET", "/profiles").ConfigureAwait(false);
        if (list["profiles"] is not JsonArray arr) throw new InvalidOperationException("Profile not found");
        foreach (var item in arr)
        {
            if (item is not JsonObject obj) continue;
            if (string.Equals((string?)obj["id"], nameOrId, StringComparison.OrdinalIgnoreCase)
                || string.Equals((string?)obj["name"], nameOrId, StringComparison.OrdinalIgnoreCase))
            {
                return (string?)obj["id"] ?? throw new InvalidOperationException("Profile missing id");
            }
        }
        throw new InvalidOperationException($"Profile not found: {nameOrId}");
    }

    // -- HTTP helpers ---------------------------------------------------

    private static async Task<JsonObject> ApiCall(string method, string path, JsonObject? body = null)
    {
        using var req = new HttpRequestMessage(new HttpMethod(method), path);
        if (body is not null)
        {
            req.Content = JsonContent.Create<JsonNode>(body);
        }
        var resp = await Http.SendAsync(req).ConfigureAwait(false);
        var text = await resp.Content.ReadAsStringAsync().ConfigureAwait(false);
        if (string.IsNullOrWhiteSpace(text)) return new JsonObject();
        try { return JsonNode.Parse(text) as JsonObject ?? new JsonObject { ["raw"] = text }; }
        catch (JsonException) { return new JsonObject { ["raw"] = text }; }
    }

    private static Task<JsonObject> ApiCallPut(string path, JsonObject body)
        => ApiCall("PUT", path, body);

    // -- JSON-RPC I/O ---------------------------------------------------

    private static void Respond(JsonNode? id, JsonObject result)
    {
        var msg = new JsonObject
        {
            ["jsonrpc"] = "2.0",
            ["result"] = result,
        };
        if (id is not null) msg["id"] = id.DeepClone();
        Console.Out.WriteLine(msg.ToJsonString());
        Console.Out.Flush();
    }

    private static void RespondError(JsonNode? id, int code, string message)
    {
        var msg = new JsonObject
        {
            ["jsonrpc"] = "2.0",
            ["error"] = new JsonObject { ["code"] = code, ["message"] = message },
        };
        if (id is not null) msg["id"] = id.DeepClone();
        Console.Out.WriteLine(msg.ToJsonString());
        Console.Out.Flush();
    }

    // -- Result helpers -------------------------------------------------

    private static JsonObject TextResult(string text) => new()
    {
        ["content"] = new JsonArray { new JsonObject { ["type"] = "text", ["text"] = text } },
    };

    private static JsonObject ErrorResult(string msg) => new()
    {
        ["content"] = new JsonArray { new JsonObject { ["type"] = "text", ["text"] = "Error: " + msg } },
        ["isError"] = true,
    };

    private static string JsonString(JsonNode? value)
    {
        if (value is null) return "null";
        return value.ToJsonString(new JsonSerializerOptions { WriteIndented = false });
    }

    private static string RequireArg(JsonObject args, string key)
    {
        var v = args[key];
        if (v is null) throw new InvalidOperationException($"Missing required parameter: {key}");
        if (v is JsonValue jv && jv.TryGetValue<string>(out var s)) return s;
        return v.ToJsonString();
    }
}
