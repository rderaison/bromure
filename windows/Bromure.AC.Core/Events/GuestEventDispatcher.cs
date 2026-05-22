using System.Collections.Concurrent;

namespace Bromure.AC.Core.Events;

/// <summary>
/// Pure routing layer for the guest→host event channel. The
/// AF_HYPERV listener (in Bromure.AC.Display.GuestEventServer)
/// receives raw payload bytes and delegates parsing/dispatch here.
/// Lives in Bromure.AC.Core because xunit can't ProjectReference
/// the WPF WinExe — and there's no platform-specific code here
/// either, just dictionaries and string parsing.
///
/// <para>Line framing (matches the in-VM bromure-title-pusher
/// guest agent):</para>
/// <list type="bullet">
///   <item><c>tab|&lt;UUID-no-dashes&gt;|&lt;TITLE&gt;</c></item>
///   <item><c>closed|&lt;UUID-no-dashes&gt;</c></item>
///   <item><c>alive|&lt;UUID&gt;,&lt;UUID&gt;,...</c> (empty roster is legal)</item>
///   <item><c>ip|&lt;IPv4&gt;</c></item>
///   <item>anything else → legacy whole-window title</item>
/// </list>
/// </summary>
public sealed class GuestEventDispatcher
{
    private readonly ConcurrentDictionary<Guid, Action<string>> _titleByVmId = new();
    private readonly ConcurrentDictionary<(Guid VmId, Guid TabUuid), Action<string>> _tabTitleByKey = new();
    private readonly ConcurrentDictionary<(Guid VmId, Guid TabUuid), Action> _tabClosedByKey = new();
    private readonly ConcurrentDictionary<Guid, Action<IReadOnlySet<Guid>>> _aliveByVmId = new();
    private readonly ConcurrentDictionary<Guid, Action<string>> _ipByVmId = new();

    public void SubscribeLegacyTitle(Guid vmId, Action<string>? onTitle)
    {
        if (vmId == Guid.Empty) return;
        if (onTitle is null) _titleByVmId.TryRemove(vmId, out _);
        else _titleByVmId[vmId] = onTitle;
    }

    public void SubscribeTab(Guid vmId, Guid tabUuid, Action<string>? onTitle)
    {
        if (vmId == Guid.Empty || tabUuid == Guid.Empty) return;
        var key = (vmId, tabUuid);
        if (onTitle is null) _tabTitleByKey.TryRemove(key, out _);
        else _tabTitleByKey[key] = onTitle;
    }

    public void SubscribeTabClosed(Guid vmId, Guid tabUuid, Action? onClosed)
    {
        if (vmId == Guid.Empty || tabUuid == Guid.Empty) return;
        var key = (vmId, tabUuid);
        if (onClosed is null) _tabClosedByKey.TryRemove(key, out _);
        else _tabClosedByKey[key] = onClosed;
    }

    public void SubscribeAlive(Guid vmId, Action<IReadOnlySet<Guid>>? onAlive)
    {
        if (vmId == Guid.Empty) return;
        if (onAlive is null) _aliveByVmId.TryRemove(vmId, out _);
        else _aliveByVmId[vmId] = onAlive;
    }

    public void SubscribeIp(Guid vmId, Action<string>? onIp)
    {
        if (vmId == Guid.Empty) return;
        if (onIp is null) _ipByVmId.TryRemove(vmId, out _);
        else _ipByVmId[vmId] = onIp;
    }

    public DispatchCounts Dispatch(Guid vmId, string rawPayload)
    {
        var payload = rawPayload.Replace("\r\n", "\n");
        var counts = new DispatchCounts();
        foreach (var rawLine in payload.Split('\n'))
        {
            var line = rawLine.Trim();
            if (line.Length == 0) continue;
            if (line.StartsWith("tab|", StringComparison.Ordinal))
            {
                var rest = line.Substring(4);
                int bar = rest.IndexOf('|');
                if (bar <= 0) continue;
                var uuidStr = rest.Substring(0, bar);
                var title = rest.Substring(bar + 1);
                if (!Guid.TryParseExact(uuidStr, "N", out var tabUuid)) continue;
                if (_tabTitleByKey.TryGetValue((vmId, tabUuid), out var cb))
                {
                    try { cb(title); } catch { }
                    counts.Tab++;
                }
            }
            else if (line.StartsWith("closed|", StringComparison.Ordinal))
            {
                var uuidStr = line.Substring(7);
                if (!Guid.TryParseExact(uuidStr, "N", out var tabUuid)) continue;
                // Use TryRemove: a tab only closes once, so the
                // subscription auto-clears after firing — keeps the
                // dictionary from growing unbounded over a long
                // session lifecycle.
                if (_tabClosedByKey.TryRemove((vmId, tabUuid), out var cb))
                {
                    try { cb(); } catch { }
                    counts.Closed++;
                }
                // Also clear any tab-title subscription for the dead
                // tab — there's no chance of more title pushes for it.
                _tabTitleByKey.TryRemove((vmId, tabUuid), out _);
            }
            else if (line.StartsWith("alive|", StringComparison.Ordinal))
            {
                var rest = line.Substring(6);
                var set = new HashSet<Guid>();
                if (rest.Length > 0)
                {
                    foreach (var tok in rest.Split(','))
                    {
                        if (Guid.TryParseExact(tok, "N", out var g)) set.Add(g);
                    }
                }
                if (_aliveByVmId.TryGetValue(vmId, out var cb))
                {
                    try { cb(set); } catch { }
                    counts.Alive++;
                }
            }
            else if (line.StartsWith("ip|", StringComparison.Ordinal))
            {
                var addr = line.Substring(3);
                if (addr.Length == 0) continue;
                if (_ipByVmId.TryGetValue(vmId, out var cb))
                {
                    try { cb(addr); } catch { }
                    counts.Ip++;
                }
            }
            else
            {
                if (_titleByVmId.TryGetValue(vmId, out var cb))
                {
                    try { cb(line); } catch { }
                    counts.Legacy++;
                }
            }
        }
        return counts;
    }

    public struct DispatchCounts
    {
        public int Tab;
        public int Closed;
        public int Alive;
        public int Ip;
        public int Legacy;
    }
}
