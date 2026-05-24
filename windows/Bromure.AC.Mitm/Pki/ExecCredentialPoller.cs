// macos-source: Sources/AgentCoding/Mitm/CloudCredentials.swift @ 4ad60b2bf2c8
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Text.Json;
using Bromure.AC.Mitm.Swap;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;

namespace Bromure.AC.Mitm.Pki;

/// <summary>
/// Direct port of <c>ExecCredentialPoller</c> from macOS
/// <c>CloudCredentials.swift</c>. Background task per kubeconfig
/// exec-plugin entry that runs the plugin every
/// <c>RefreshSeconds</c>, parses the JSON ExecCredential output, and
/// pushes the fresh bearer token into the swap map.
///
/// <para>Default for EKS / GKE / AKS today — kubectl shells out to
/// <c>aws eks get-token</c> / <c>gke-gcloud-auth-plugin</c> /
/// <c>kubelogin</c> on every request. Without this poller every k8s
/// request the agent makes 401s after the initial token expires.</para>
/// </summary>
public sealed class ExecCredentialPoller : IAsyncDisposable
{
    private readonly ILogger _log;
    private readonly ConcurrentDictionary<Guid, CancellationTokenSource> _running = new();
    private readonly ConcurrentDictionary<Guid, HashSet<Guid>> _entriesByProfile = new();
    private readonly object _gate = new();

    public ExecCredentialPoller(ILogger? log = null) => _log = log ?? NullLogger.Instance;

    /// <summary>
    /// Arm the poller for one or more exec contexts. Existing
    /// pollers for the same <c>EntryId</c> are cancelled first so
    /// repeated <c>SessionViewModel.StartAsync</c> calls don't stack.
    /// </summary>
    public void Start(IEnumerable<KubeconfigMaterializer.ExecContext> contexts,
        Guid profileId, TokenSwapper swapper)
    {
        foreach (var ctx in contexts)
        {
            Stop(ctx.EntryId);
            var cts = new CancellationTokenSource();
            _running[ctx.EntryId] = cts;
            lock (_gate)
            {
                if (!_entriesByProfile.TryGetValue(profileId, out var set))
                {
                    set = new HashSet<Guid>();
                    _entriesByProfile[profileId] = set;
                }
                set.Add(ctx.EntryId);
            }
            _ = Task.Run(() => LoopAsync(ctx, profileId, swapper, cts.Token));
        }
    }

    public void Stop(Guid entryId)
    {
        if (_running.TryRemove(entryId, out var cts))
        {
            // Cancel without disposing: LoopAsync is still running on
            // a background Task and uses this token in Task.Delay /
            // ct.Register. Disposing the CTS while it's in flight
            // throws ObjectDisposedException out of those calls,
            // which the loop's broad catch logs as a warning and
            // retries — turning the poller into an unkillable CPU
            // hog. The CTS leaks ~80 bytes per entry; the LoopAsync
            // task exits naturally once it next observes
            // IsCancellationRequested.
            try { cts.Cancel(); } catch { }
        }
        lock (_gate)
        {
            foreach (var (_, set) in _entriesByProfile)
            {
                set.Remove(entryId);
            }
        }
    }

    /// <summary>Cancel every poller arm for <paramref name="profileId"/>.
    /// Called by the engine's <c>UnregisterAsync</c> on session
    /// teardown so a previous profile's exec pollers don't keep
    /// pushing tokens after the VM closes.</summary>
    public void StopForProfile(Guid profileId)
    {
        HashSet<Guid>? entries;
        lock (_gate)
        {
            if (!_entriesByProfile.TryRemove(profileId, out entries) || entries is null) return;
        }
        foreach (var entryId in entries) Stop(entryId);
    }

    public void StopAll()
    {
        foreach (var (_, cts) in _running)
        {
            // See Stop() comment — do NOT dispose the CTS while the
            // LoopAsync background task may still be observing it.
            try { cts.Cancel(); } catch { }
        }
        _running.Clear();
        _entriesByProfile.Clear();
    }

    public ValueTask DisposeAsync() { StopAll(); return ValueTask.CompletedTask; }

    private async Task LoopAsync(KubeconfigMaterializer.ExecContext ctx,
        Guid profileId, TokenSwapper swapper, CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            try
            {
                var token = await RunExecAsync(ctx.Command, ctx.Args, ct).ConfigureAwait(false);
                if (token is not null)
                {
                    UpdateSwap(swapper, profileId, ctx.Host, ctx.FakeToken, token);
                    _log.LogDebug("k8s-exec refreshed token for {Host} ({Cmd})", ctx.Host, ctx.Command);
                }
            }
            catch (OperationCanceledException) { return; }
            catch (Exception ex)
            {
                _log.LogWarning(ex, "ExecCredentialPoller iteration failed for {Host}", ctx.Host);
            }
            var refreshSecs = ctx.RefreshSeconds > 0 ? ctx.RefreshSeconds : 60;
            try { await Task.Delay(TimeSpan.FromSeconds(refreshSecs), ct).ConfigureAwait(false); }
            catch (OperationCanceledException) { return; }
        }
    }

    /// <summary>
    /// Spawn the exec plugin and decode its <c>ExecCredential</c>
    /// JSON output, returning the bearer token. Null on any failure
    /// (process spawn, JSON shape, missing token field).
    ///
    /// <para>Format documented at
    /// https://kubernetes.io/docs/reference/access-authn-authz/authentication/#client-go-credential-plugins
    /// — <c>{"status": {"token": "…"}}</c> being the minimum shape.</para>
    /// </summary>
    internal static async Task<string?> RunExecAsync(string command, IReadOnlyList<string> args,
        CancellationToken ct)
    {
        var psi = new ProcessStartInfo
        {
            FileName = command,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
        };
        foreach (var a in args) psi.ArgumentList.Add(a);

        Process? proc = null;
        try { proc = Process.Start(psi); }
        catch { return null; }
        if (proc is null) return null;

        try
        {
            // Race process exit against external cancellation. The
            // poller's loop already has its own delay between runs,
            // so a long-hanging credential plugin gets killed when
            // the session ends.
            var stdoutTask = proc.StandardOutput.ReadToEndAsync();
            await using var _ = ct.Register(() =>
            {
                try { if (!proc.HasExited) proc.Kill(entireProcessTree: true); }
                catch { }
            });
            await proc.WaitForExitAsync(ct).ConfigureAwait(false);
            if (proc.ExitCode != 0) return null;
            var json = await stdoutTask.ConfigureAwait(false);
            return ParseToken(json);
        }
        catch (OperationCanceledException) { return null; }
        finally
        {
            try { proc.Dispose(); } catch { }
        }
    }

    /// <summary>
    /// Extract <c>.status.token</c> from a kubernetes ExecCredential
    /// JSON document. Returns null on any structural mismatch — the
    /// caller treats null as "skip this round, keep prior token".
    /// </summary>
    internal static string? ParseToken(string json)
    {
        if (string.IsNullOrWhiteSpace(json)) return null;
        try
        {
            using var doc = JsonDocument.Parse(json);
            if (doc.RootElement.ValueKind != JsonValueKind.Object) return null;
            if (!doc.RootElement.TryGetProperty("status", out var status)) return null;
            if (status.ValueKind != JsonValueKind.Object) return null;
            if (!status.TryGetProperty("token", out var tok)) return null;
            if (tok.ValueKind != JsonValueKind.String) return null;
            var value = tok.GetString();
            return string.IsNullOrEmpty(value) ? null : value;
        }
        catch (JsonException) { return null; }
    }

    private static void UpdateSwap(TokenSwapper swapper, Guid profileId,
        string host, string fake, string real)
    {
        // Replace the entry with a matching fake. The swapper exposes
        // SetMap / EntriesFor — there's no per-entry mutator yet, so
        // we round-trip the full list. Consent metadata on the prior
        // entry is preserved to keep the per-cluster gate flag intact.
        var entries = swapper.EntriesFor(profileId).ToList();
        var prior = entries.FirstOrDefault(e => e.Fake == fake);
        entries.RemoveAll(e => e.Fake == fake);
        entries.Add(new TokenMap.Entry(
            Fake: fake,
            Real: real,
            Host: host,
            Header: prior?.Header ?? EntryHeader.Authorization,
            ConsentCredentialId: prior?.ConsentCredentialId,
            ConsentDisplayName: prior?.ConsentDisplayName));
        swapper.SetMap(new TokenMap(entries), profileId);
    }
}
