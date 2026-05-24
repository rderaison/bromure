// macos-source: Sources/AgentCoding/MCPOAuthBroker.swift @ 5feff2fd78b5
using System.Diagnostics;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using Bromure.AC.Core.Model;

namespace Bromure.AC.Mitm.OAuth;

/// <summary>
/// MCP OAuth discovery + dynamic client registration + PKCE authorization-
/// code flow for HTTP MCP servers. Runs entirely on the host — the VM
/// never sees real OAuth credentials.
///
/// <para>Uses a localhost HTTP listener (TCP port 28500–28599) for the
/// OAuth callback because real-world MCP servers (Fellow, etc.) reject
/// custom URL schemes in redirect_uris. Browser launch is done via
/// <c>ShellExecute</c> (parity with macOS's <c>NSWorkspace.open</c>).</para>
/// </summary>
public sealed class McpOAuthBroker
{
    public const ushort PortRangeStart = 28500;
    public const ushort PortRangeEnd = 28599;

    private static readonly HttpClient Http = new();
    private TcpListener? _callbackListener;

    public sealed record AuthResult(
        string AccessToken,
        string? RefreshToken,
        int? ExpiresIn,
        string ClientId,
        string? ClientSecret,
        string AuthorizationEndpoint,
        string TokenEndpoint,
        string? RegistrationEndpoint,
        ushort CallbackPort);

    private sealed record AuthMetadata(
        Uri AuthorizationEndpoint,
        Uri TokenEndpoint,
        Uri? RegistrationEndpoint);

    private sealed record ClientRegistration(string ClientId, string? ClientSecret);

    /// <summary>
    /// Drive the full OAuth flow for an HTTP MCP server URL. When
    /// <paramref name="existingState"/> is supplied we try to reuse its
    /// client registration + callback port — many providers accept only
    /// the redirect_uri the client was registered with.
    /// </summary>
    public async Task<AuthResult> AuthorizeServerAsync(
        string serverUrl,
        McpOAuthState? existingState = null,
        CancellationToken ct = default)
    {
        if (!Uri.TryCreate(serverUrl, UriKind.Absolute, out var parsedUrl))
            throw new InvalidOperationException("Invalid server URL");

        AuthMetadata metadata;
        if (existingState is not null
            && Uri.TryCreate(existingState.AuthorizationEndpoint, UriKind.Absolute, out var existingAuth)
            && Uri.TryCreate(existingState.TokenEndpoint, UriKind.Absolute, out var existingToken))
        {
            Uri? reg = null;
            if (!string.IsNullOrEmpty(existingState.RegistrationEndpoint))
                Uri.TryCreate(existingState.RegistrationEndpoint, UriKind.Absolute, out reg);
            metadata = new AuthMetadata(existingAuth, existingToken, reg);
        }
        else
        {
            metadata = await DiscoverMetadataAsync(parsedUrl, ct).ConfigureAwait(false);
        }

        var preferredPort = existingState?.CallbackPort;
        var (redirectUri, port) = StartCallbackListener(preferredPort);
        var canReuseClient = preferredPort is { } p && p == port;
        try
        {
            ClientRegistration client;
            if (existingState is not null && !string.IsNullOrEmpty(existingState.ClientId) && canReuseClient)
            {
                client = new ClientRegistration(existingState.ClientId, existingState.ClientSecret);
            }
            else
            {
                client = await RegisterClientAsync(metadata, redirectUri, ct).ConfigureAwait(false);
            }

            var (code, verifier) = await AuthorizeAsync(metadata, client, redirectUri, ct).ConfigureAwait(false);
            return await ExchangeCodeAsync(code, metadata, client, verifier, redirectUri, port, ct).ConfigureAwait(false);
        }
        finally
        {
            try { _callbackListener?.Stop(); } catch { }
            _callbackListener = null;
        }
    }

    /// <summary>Refresh an existing OAuth state via refresh_token grant.</summary>
    public static async Task<McpOAuthState> RefreshAsync(McpOAuthState state, CancellationToken ct = default)
    {
        if (string.IsNullOrEmpty(state.RefreshToken))
            throw new InvalidOperationException("No refresh token");
        if (!Uri.TryCreate(state.TokenEndpoint, UriKind.Absolute, out var tokenUrl))
            throw new InvalidOperationException("Invalid token endpoint");

        var body = new List<string>
        {
            "grant_type=refresh_token",
            "refresh_token=" + FormEncode(state.RefreshToken),
            "client_id=" + FormEncode(state.ClientId),
        };
        if (!string.IsNullOrEmpty(state.ClientSecret))
            body.Add("client_secret=" + FormEncode(state.ClientSecret));

        using var req = new HttpRequestMessage(HttpMethod.Post, tokenUrl)
        {
            Content = new StringContent(string.Join("&", body), Encoding.UTF8, "application/x-www-form-urlencoded"),
        };
        var resp = await Http.SendAsync(req, ct).ConfigureAwait(false);
        if (!resp.IsSuccessStatusCode)
            throw new InvalidOperationException($"Refresh failed: HTTP {(int)resp.StatusCode}");

        var json = await resp.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
        using var doc = System.Text.Json.JsonDocument.Parse(json);
        var root = doc.RootElement;
        if (!root.TryGetProperty("access_token", out var atEl))
            throw new InvalidOperationException("Refresh: missing access_token");

        return new McpOAuthState
        {
            ClientId = state.ClientId,
            ClientSecret = state.ClientSecret,
            AuthorizationEndpoint = state.AuthorizationEndpoint,
            TokenEndpoint = state.TokenEndpoint,
            RegistrationEndpoint = state.RegistrationEndpoint,
            AccessToken = atEl.GetString() ?? "",
            RefreshToken = root.TryGetProperty("refresh_token", out var rtEl) && rtEl.ValueKind == System.Text.Json.JsonValueKind.String
                ? rtEl.GetString()
                : state.RefreshToken,
            ExpiresAt = root.TryGetProperty("expires_in", out var exEl) && exEl.TryGetInt32(out var ex)
                ? DateTimeOffset.UtcNow.AddSeconds(ex)
                : state.ExpiresAt,
            AuthorizedAt = state.AuthorizedAt,
            CallbackPort = state.CallbackPort,
        };
    }

    // -- Listener -------------------------------------------------------

    private (string RedirectUri, ushort Port) StartCallbackListener(ushort? preferredPort)
    {
        var candidates = new List<ushort>();
        if (preferredPort is { } p && p >= PortRangeStart && p <= PortRangeEnd) candidates.Add(p);
        for (var port = PortRangeStart; port <= PortRangeEnd; port++)
        {
            if (!candidates.Contains(port)) candidates.Add(port);
        }
        foreach (var port in candidates)
        {
            try
            {
                var listener = new TcpListener(IPAddress.Loopback, port);
                listener.Start(1);
                _callbackListener = listener;
                return ($"http://127.0.0.1:{port}/callback", port);
            }
            catch (SocketException) { /* port taken — try next */ }
        }
        throw new InvalidOperationException($"No available port in {PortRangeStart}-{PortRangeEnd}");
    }

    private async Task<string> WaitForCallbackAsync(string state, CancellationToken ct)
    {
        if (_callbackListener is null) throw new InvalidOperationException("Listener not started");
        using var client = await _callbackListener.AcceptTcpClientAsync(ct).ConfigureAwait(false);
        using var stream = client.GetStream();
        // Loop until we see the end-of-headers delimiter or hit the
        // buffer cap. A single ReadAsync can return less than a full
        // HTTP request line if the browser (or an interception layer
        // like a corp AV) fragments the TCP stream — the older
        // single-read code surfaced as flaky OAuth failures with
        // "Bad request line" errors that needed a manual retry.
        var buf = new byte[8192];
        var got = 0;
        while (got < buf.Length)
        {
            var n = await stream.ReadAsync(buf.AsMemory(got, buf.Length - got), ct).ConfigureAwait(false);
            if (n <= 0) break;
            got += n;
            var sliceEnd = got;
            // Found CRLF CRLF — full headers in hand, body (if any) is irrelevant for GET /callback.
            if (got >= 4)
            {
                var foundEnd = false;
                for (var i = 0; i <= got - 4; i++)
                {
                    if (buf[i] == 0x0D && buf[i + 1] == 0x0A
                        && buf[i + 2] == 0x0D && buf[i + 3] == 0x0A)
                    {
                        foundEnd = true; break;
                    }
                }
                if (foundEnd) break;
            }
            _ = sliceEnd;
        }
        if (got <= 0) throw new InvalidOperationException("Empty callback");

        var raw = Encoding.UTF8.GetString(buf, 0, got);
        var firstLine = raw.Split("\r\n", 2)[0];
        var parts = firstLine.Split(' ');
        if (parts.Length < 2) throw new InvalidOperationException("Bad request line");

        var path = parts[1];
        var queryIdx = path.IndexOf('?');
        var qs = queryIdx >= 0 ? path[(queryIdx + 1)..] : "";
        var query = ParseQuery(qs);

        if (!query.TryGetValue("code", out var code)
            || !query.TryGetValue("state", out var returnedState)
            || returnedState != state)
        {
            const string err = "Authorization failed.";
            var resp = $"HTTP/1.1 400 Bad Request\r\nContent-Length: {err.Length}\r\nConnection: close\r\n\r\n{err}";
            await stream.WriteAsync(Encoding.ASCII.GetBytes(resp), ct).ConfigureAwait(false);
            throw new InvalidOperationException("Invalid callback — missing code or state mismatch");
        }

        const string body = "<html><body style=\"font-family:system-ui;text-align:center;padding:60px\">" +
            "<h2>Authorized</h2><p>You can close this tab and return to Bromure AC.</p></body></html>";
        var ok = $"HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: {body.Length}\r\nConnection: close\r\n\r\n{body}";
        await stream.WriteAsync(Encoding.ASCII.GetBytes(ok), ct).ConfigureAwait(false);
        return code;
    }

    // -- Discovery (RFC 8414) -------------------------------------------

    private static async Task<AuthMetadata> DiscoverMetadataAsync(Uri serverUrl, CancellationToken ct)
    {
        var b = new UriBuilder(serverUrl)
        {
            Path = "/.well-known/oauth-authorization-server",
            Query = "",
            Fragment = "",
        };
        var resp = await Http.GetAsync(b.Uri, ct).ConfigureAwait(false);
        if (!resp.IsSuccessStatusCode)
            throw new InvalidOperationException($"Discovery returned HTTP {(int)resp.StatusCode}");

        var json = await resp.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
        using var doc = System.Text.Json.JsonDocument.Parse(json);
        var root = doc.RootElement;
        if (!root.TryGetProperty("authorization_endpoint", out var authEl)
            || !Uri.TryCreate(authEl.GetString(), UriKind.Absolute, out var authUrl)
            || !root.TryGetProperty("token_endpoint", out var tokenEl)
            || !Uri.TryCreate(tokenEl.GetString(), UriKind.Absolute, out var tokenUrl))
        {
            throw new InvalidOperationException("Discovery missing required endpoints");
        }
        Uri? regUrl = null;
        if (root.TryGetProperty("registration_endpoint", out var regEl)
            && Uri.TryCreate(regEl.GetString(), UriKind.Absolute, out var parsedReg))
        {
            regUrl = parsedReg;
        }
        return new AuthMetadata(authUrl, tokenUrl, regUrl);
    }

    // -- Dynamic Client Registration (RFC 7591) -------------------------

    private static async Task<ClientRegistration> RegisterClientAsync(
        AuthMetadata metadata, string redirectUri, CancellationToken ct)
    {
        if (metadata.RegistrationEndpoint is null)
            throw new InvalidOperationException("Server does not support dynamic client registration");

        var payload = new System.Text.Json.Nodes.JsonObject
        {
            ["client_name"] = "Bromure AC",
            ["redirect_uris"] = new System.Text.Json.Nodes.JsonArray(redirectUri),
            ["grant_types"] = new System.Text.Json.Nodes.JsonArray("authorization_code"),
            ["response_types"] = new System.Text.Json.Nodes.JsonArray("code"),
            ["token_endpoint_auth_method"] = "none",
        };
        using var req = new HttpRequestMessage(HttpMethod.Post, metadata.RegistrationEndpoint)
        {
            Content = new StringContent(payload.ToJsonString(), Encoding.UTF8, "application/json"),
        };
        var resp = await Http.SendAsync(req, ct).ConfigureAwait(false);
        var body = await resp.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
        if (resp.StatusCode is not (HttpStatusCode.OK or HttpStatusCode.Created))
            throw new InvalidOperationException($"Registration failed: HTTP {(int)resp.StatusCode}: {body}");

        using var doc = System.Text.Json.JsonDocument.Parse(body);
        if (!doc.RootElement.TryGetProperty("client_id", out var cidEl))
            throw new InvalidOperationException("Registration missing client_id");
        return new ClientRegistration(
            ClientId: cidEl.GetString() ?? "",
            ClientSecret: doc.RootElement.TryGetProperty("client_secret", out var csEl) ? csEl.GetString() : null);
    }

    // -- Authorization (PKCE + System Browser) --------------------------

    private async Task<(string Code, string Verifier)> AuthorizeAsync(
        AuthMetadata metadata, ClientRegistration client, string redirectUri, CancellationToken ct)
    {
        var verifier = GenerateCodeVerifier();
        var challenge = CodeChallenge(verifier);
        var state = Guid.NewGuid().ToString("N");

        var qs = string.Join("&", new[]
        {
            "response_type=code",
            "client_id=" + FormEncode(client.ClientId),
            "redirect_uri=" + FormEncode(redirectUri),
            "code_challenge=" + FormEncode(challenge),
            "code_challenge_method=S256",
            "state=" + FormEncode(state),
        });
        var authUrl = metadata.AuthorizationEndpoint.AbsoluteUri
            + (metadata.AuthorizationEndpoint.Query.Length > 0 ? "&" : "?") + qs;

        // Launch the system default browser. ShellExecute is the
        // Windows-native equivalent of macOS NSWorkspace.open — Process.Start
        // with UseShellExecute=true delegates to the URL handler.
        try
        {
            Process.Start(new ProcessStartInfo { FileName = authUrl, UseShellExecute = true });
        }
        catch (Exception ex)
        {
            throw new InvalidOperationException($"Could not launch browser for OAuth: {ex.Message}", ex);
        }

        var code = await WaitForCallbackAsync(state, ct).ConfigureAwait(false);
        return (code, verifier);
    }

    // -- Token Exchange -------------------------------------------------

    private static async Task<AuthResult> ExchangeCodeAsync(
        string code,
        AuthMetadata metadata,
        ClientRegistration client,
        string codeVerifier,
        string redirectUri,
        ushort callbackPort,
        CancellationToken ct)
    {
        var body = new List<string>
        {
            "grant_type=authorization_code",
            "code=" + FormEncode(code),
            "redirect_uri=" + FormEncode(redirectUri),
            "client_id=" + FormEncode(client.ClientId),
            "code_verifier=" + FormEncode(codeVerifier),
        };
        if (!string.IsNullOrEmpty(client.ClientSecret))
            body.Add("client_secret=" + FormEncode(client.ClientSecret));

        using var req = new HttpRequestMessage(HttpMethod.Post, metadata.TokenEndpoint)
        {
            Content = new StringContent(string.Join("&", body), Encoding.UTF8, "application/x-www-form-urlencoded"),
        };
        var resp = await Http.SendAsync(req, ct).ConfigureAwait(false);
        if (!resp.IsSuccessStatusCode)
            throw new InvalidOperationException($"Token exchange failed: HTTP {(int)resp.StatusCode}");

        var json = await resp.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
        using var doc = System.Text.Json.JsonDocument.Parse(json);
        var root = doc.RootElement;
        if (!root.TryGetProperty("access_token", out var atEl))
            throw new InvalidOperationException("Token exchange: missing access_token");

        return new AuthResult(
            AccessToken: atEl.GetString() ?? "",
            RefreshToken: root.TryGetProperty("refresh_token", out var rtEl) && rtEl.ValueKind == System.Text.Json.JsonValueKind.String
                ? rtEl.GetString() : null,
            ExpiresIn: root.TryGetProperty("expires_in", out var exEl) && exEl.TryGetInt32(out var ex) ? ex : null,
            ClientId: client.ClientId,
            ClientSecret: client.ClientSecret,
            AuthorizationEndpoint: metadata.AuthorizationEndpoint.AbsoluteUri,
            TokenEndpoint: metadata.TokenEndpoint.AbsoluteUri,
            RegistrationEndpoint: metadata.RegistrationEndpoint?.AbsoluteUri,
            CallbackPort: callbackPort);
    }

    // -- PKCE Helpers ---------------------------------------------------

    private static string GenerateCodeVerifier()
    {
        var bytes = RandomNumberGenerator.GetBytes(32);
        return Base64Url(bytes);
    }

    private static string CodeChallenge(string verifier)
        => Base64Url(SHA256.HashData(Encoding.UTF8.GetBytes(verifier)));

    internal static string Base64Url(byte[] bytes)
        => Convert.ToBase64String(bytes).Replace('+', '-').Replace('/', '_').TrimEnd('=');

    private static readonly HashSet<char> FormSafe = new(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~");

    internal static string FormEncode(string s)
    {
        var sb = new StringBuilder(s.Length);
        foreach (var c in s)
        {
            if (FormSafe.Contains(c)) { sb.Append(c); continue; }
            foreach (var b in Encoding.UTF8.GetBytes(new[] { c })) sb.Append('%').Append(b.ToString("X2"));
        }
        return sb.ToString();
    }

    private static Dictionary<string, string> ParseQuery(string query)
    {
        var result = new Dictionary<string, string>(StringComparer.Ordinal);
        if (string.IsNullOrEmpty(query)) return result;
        foreach (var pair in query.Split('&'))
        {
            var eq = pair.IndexOf('=');
            if (eq < 0) continue;
            var key = Uri.UnescapeDataString(pair[..eq].Replace('+', ' '));
            var val = Uri.UnescapeDataString(pair[(eq + 1)..].Replace('+', ' '));
            result[key] = val;
        }
        return result;
    }
}
