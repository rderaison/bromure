using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;

namespace Bromure.SandboxEngine.Hcs.Native;

/// <summary>
/// Minimal P/Invoke surface for the Host Compute Network (HCN) APIs in
/// <c>computenetwork.dll</c>. Used by Bromure to:
/// <list type="bullet">
///   <item>Find the HNS network behind a Hyper-V <c>VMSwitch</c>
///   (Windows synthesises an HNS network per switch; the IDs match).</item>
///   <item>Create a transient HNS endpoint on that network and pass
///   its GUID to <see cref="HcsSchema.NetworkAdapter.EndpointId"/>.
///   The HCS VM then gets a NIC bound to the switch and a DHCP IP
///   from whatever serves the subnet.</item>
///   <item>Delete the endpoint when the session ends.</item>
/// </list>
/// hcsshim's Go implementation has the same shape. JSON in / JSON out
/// for everything; the HCN error codes come back in the result document.
/// </summary>
public static class HcnApi
{
    // Most HCN functions return HRESULT (0 = success).

    [DllImport("computenetwork.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    public static extern int HcnEnumerateNetworks(string query, out IntPtr networks, out IntPtr errorRecord);

    [DllImport("computenetwork.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    public static extern int HcnOpenNetwork(ref Guid id, out IntPtr network, out IntPtr errorRecord);

    [DllImport("computenetwork.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    public static extern int HcnCloseNetwork(IntPtr network);

    [DllImport("computenetwork.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    public static extern int HcnCreateEndpoint(IntPtr network, ref Guid id, string settings,
        out IntPtr endpoint, out IntPtr errorRecord);

    [DllImport("computenetwork.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    public static extern int HcnCloseEndpoint(IntPtr endpoint);

    [DllImport("computenetwork.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    public static extern int HcnQueryEndpointProperties(IntPtr endpoint, string query,
        out IntPtr properties, out IntPtr errorRecord);

    [DllImport("computenetwork.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    public static extern int HcnDeleteEndpoint(ref Guid id, out IntPtr errorRecord);

    [DllImport("api-ms-win-core-com-l1-1-0.dll", ExactSpelling = true)]
    private static extern void CoTaskMemFree(IntPtr ptr);

    /// <summary>
    /// Enumerate all HNS networks, return the GUID of the first whose
    /// Name matches <paramref name="switchName"/>. Returns
    /// <see cref="Guid.Empty"/> if not found.
    /// </summary>
    public static Guid FindNetworkIdByName(string switchName)
    {
        // Query: "{}" enumerates ALL networks (no filter).
        var hr = HcnEnumerateNetworks("{}", out var networks, out var errRec);
        if (hr != 0)
        {
            var err = errRec != IntPtr.Zero ? Marshal.PtrToStringUni(errRec) : null;
            if (errRec != IntPtr.Zero) CoTaskMemFree(errRec);
            throw new HcsException("HcnEnumerateNetworks", hr, err);
        }
        try
        {
            var listJson = Marshal.PtrToStringUni(networks);
            if (string.IsNullOrEmpty(listJson)) return Guid.Empty;
            // listJson is a JSON array of GUID strings.
            using var doc = JsonDocument.Parse(listJson);
            foreach (var idElem in doc.RootElement.EnumerateArray())
            {
                var idStr = idElem.GetString();
                if (string.IsNullOrEmpty(idStr) || !Guid.TryParse(idStr, out var id)) continue;
                // For each network ID, open + query name.
                var openHr = HcnOpenNetwork(ref id, out var net, out var openErr);
                if (openErr != IntPtr.Zero) CoTaskMemFree(openErr);
                if (openHr != 0) continue;
                try
                {
                    // Query API uses a JSON "PropertyQuery" — empty = all props.
                    var propHr = HcnQueryNetworkProperties(net, "{}", out var props, out var propErr);
                    if (propErr != IntPtr.Zero) CoTaskMemFree(propErr);
                    if (propHr != 0) continue;
                    try
                    {
                        var propJson = Marshal.PtrToStringUni(props);
                        if (string.IsNullOrEmpty(propJson)) continue;
                        using var propDoc = JsonDocument.Parse(propJson);
                        if (!propDoc.RootElement.TryGetProperty("Name", out var nameEl)) continue;
                        if (string.Equals(nameEl.GetString(), switchName, StringComparison.OrdinalIgnoreCase))
                        {
                            return id;
                        }
                    }
                    finally
                    {
                        if (props != IntPtr.Zero) CoTaskMemFree(props);
                    }
                }
                finally { HcnCloseNetwork(net); }
            }
            return Guid.Empty;
        }
        finally
        {
            if (networks != IntPtr.Zero) CoTaskMemFree(networks);
        }
    }

    [DllImport("computenetwork.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern int HcnQueryNetworkProperties(IntPtr network, string query,
        out IntPtr properties, out IntPtr errorRecord);

    /// <summary>
    /// Create a new HNS endpoint bound to <paramref name="networkId"/>.
    /// Returns the new endpoint's GUID. Caller must call
    /// <see cref="DeleteEndpoint"/> when done — otherwise the endpoint
    /// leaks across reboots.
    /// </summary>
    public static Guid CreateEndpoint(Guid networkId, string macAddress)
    {
        var endpointId = Guid.NewGuid();
        var settings = new
        {
            // SchemaVersion required for HNS 2.x endpoints (the modern
            // path that HCS schema 2.5 wants).
            SchemaVersion = new { Major = 2, Minor = 0 },
            // The Owner string is what shows up in HNS tooling as the
            // creator; helps tell our endpoints apart from Docker /
            // WSL ones at debug time.
            Owner = "Bromure",
            HostComputeNetwork = networkId.ToString("D"),
            MacAddress = macAddress,
            // Required: HCN needs to be told what HOST network this
            // endpoint sits on AND opt into the endpoint being usable
            // by a compute system (HCS). Without the flags below the
            // create call returns E_INVALIDARG.
            Flags = 0,
        };
        var settingsJson = JsonSerializer.Serialize(settings);
        // First-attempt diagnostics: HNS rejection reasons are noisy
        // and the JSON we send is critical. Print it once at info
        // level so the failure trail is self-contained.
        Console.Error.WriteLine("[hcn] HcnCreateEndpoint settings: " + settingsJson);
        // First open the network — HcnCreateEndpoint takes the network
        // HANDLE, not its GUID. Passing IntPtr.Zero returns
        // E_INVALIDARG even with otherwise-valid settings.
        var openHr = HcnOpenNetwork(ref networkId, out var netHandle, out var openErr);
        if (openErr != IntPtr.Zero) CoTaskMemFree(openErr);
        if (openHr != 0)
        {
            throw new HcsException("HcnOpenNetwork (network=" + networkId + ")", openHr, null);
        }
        try
        {
            var hr = HcnCreateEndpoint(netHandle, ref endpointId, settingsJson, out var ep, out var errRec);
            var err = errRec != IntPtr.Zero ? Marshal.PtrToStringUni(errRec) : null;
            if (errRec != IntPtr.Zero) CoTaskMemFree(errRec);
            if (hr != 0)
            {
                throw new HcsException("HcnCreateEndpoint (network=" + networkId + ")", hr, err);
            }
            HcnCloseEndpoint(ep);
            return endpointId;
        }
        finally { HcnCloseNetwork(netHandle); }
    }

    /// <summary>Delete an HNS endpoint by GUID. Best-effort.</summary>
    public static void DeleteEndpoint(Guid endpointId)
    {
        try
        {
            HcnDeleteEndpoint(ref endpointId, out var errRec);
            if (errRec != IntPtr.Zero) CoTaskMemFree(errRec);
        }
        catch { }
    }

    /// <summary>Random locally-administered MAC. First octet's bit 1 set,
    /// bit 0 clear (unicast, locally administered). Stays unique within
    /// a session run; collisions across many concurrent sessions are
    /// astronomically unlikely.</summary>
    public static string RandomMacAddress()
    {
        var rng = System.Security.Cryptography.RandomNumberGenerator.GetBytes(6);
        rng[0] = (byte)((rng[0] & 0xFE) | 0x02);
        var sb = new StringBuilder(17);
        for (var i = 0; i < 6; i++)
        {
            if (i > 0) sb.Append('-');
            sb.Append(rng[i].ToString("X2"));
        }
        return sb.ToString();
    }
}
