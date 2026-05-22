using Bromure.AC.Core.Model;
using Bromure.Platform;
using FluentAssertions;
using Xunit;

namespace Bromure.Tests;

/// <summary>
/// Coverage for the per-profile stable MAC binding. Direct port of
/// macOS MACBindings (Profile.swift:1565-1638). Without this every
/// session VM got a fresh random MAC, so DHCP leases / port-forward
/// rules / host firewall allow-lists drift on every launch.
/// </summary>
public class MacAddressBindingsTests
{
    [Fact]
    public void GenerateLaaMac_HasLocallyAdministeredBitSet()
    {
        for (var i = 0; i < 50; i++)
        {
            var mac = MacAddressBindings.GenerateLaaMac();
            MacAddressBindings.IsValid(mac).Should().BeTrue();
            // First-octet LSB-pair encodes LAA + unicast/multicast.
            // RFC 7042: LAA bit = 0x02 set, multicast bit = 0x01 clear.
            var firstOctet = Convert.ToByte(mac[..2], 16);
            (firstOctet & 0x02).Should().Be(0x02, "LAA bit must be set");
            (firstOctet & 0x01).Should().Be(0x00, "multicast bit must be clear");
        }
    }

    [Fact]
    public void GenerateLaaMac_RandomCollisionImpossibleInPractice()
    {
        var set = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        for (var i = 0; i < 100; i++)
        {
            set.Add(MacAddressBindings.GenerateLaaMac());
        }
        set.Count.Should().Be(100, "100 LAA MACs should collide with probability ~1e-12");
    }

    [Fact]
    public void GetOrCreate_FirstCall_Persists()
    {
        using var paths = new TestPaths();
        var bindings = new MacAddressBindings(paths);
        var profileId = Guid.NewGuid();
        var first = bindings.GetOrCreate(profileId);
        MacAddressBindings.IsValid(first).Should().BeTrue();
        // Read-back: a new instance must see the same MAC (proves
        // the JSON was actually written).
        var bindings2 = new MacAddressBindings(paths);
        bindings2.GetOrCreate(profileId).Should().Be(first);
    }

    [Fact]
    public void GetOrCreate_SecondCall_ReturnsSameMac()
    {
        using var paths = new TestPaths();
        var bindings = new MacAddressBindings(paths);
        var profileId = Guid.NewGuid();
        var first = bindings.GetOrCreate(profileId);
        var second = bindings.GetOrCreate(profileId);
        second.Should().Be(first, "stable MAC is the whole point");
    }

    [Fact]
    public void GetOrCreate_DifferentProfiles_DifferentMacs()
    {
        using var paths = new TestPaths();
        var bindings = new MacAddressBindings(paths);
        var a = bindings.GetOrCreate(Guid.NewGuid());
        var b = bindings.GetOrCreate(Guid.NewGuid());
        a.Should().NotBe(b);
    }

    [Fact]
    public void Forget_RemovesEntry_GetOrCreateMintsNew()
    {
        using var paths = new TestPaths();
        var bindings = new MacAddressBindings(paths);
        var profileId = Guid.NewGuid();
        var first = bindings.GetOrCreate(profileId);
        bindings.Forget(profileId);
        var second = bindings.GetOrCreate(profileId);
        second.Should().NotBe(first);
    }

    [Fact]
    public async Task GetOrCreate_ConcurrentCallsForSameProfile_OneMac()
    {
        // Split-screen edit + launch races shouldn't mint two MACs
        // for the same profile.
        using var paths = new TestPaths();
        var bindings = new MacAddressBindings(paths);
        var profileId = Guid.NewGuid();

        var bag = new System.Collections.Concurrent.ConcurrentBag<string>();
        var tasks = Enumerable.Range(0, 20)
            .Select(_ => Task.Run(() => bag.Add(bindings.GetOrCreate(profileId))))
            .ToArray();
        await Task.WhenAll(tasks);
        bag.Distinct().Should().HaveCount(1, "all 20 concurrent callers must see the same MAC");
    }

    [Fact]
    public void Load_CorruptJson_StillFunctional()
    {
        using var paths = new TestPaths();
        var bindings = new MacAddressBindings(paths);
        var jsonPath = Path.Combine(paths.AppDataRoot, "profile-macs.json");
        File.WriteAllText(jsonPath, "{ not json");
        // GetOrCreate ignores the corrupt file + starts fresh.
        var mac = bindings.GetOrCreate(Guid.NewGuid());
        MacAddressBindings.IsValid(mac).Should().BeTrue();
    }

    [Fact]
    public void IsValid_AcceptsBothDashAndColonSeparators()
    {
        MacAddressBindings.IsValid("AA-BB-CC-DD-EE-FF").Should().BeTrue();
        MacAddressBindings.IsValid("aa-bb-cc-dd-ee-ff").Should().BeTrue();
        MacAddressBindings.IsValid("AA:BB:CC:DD:EE:FF").Should().BeTrue();
    }

    [Theory]
    [InlineData("")]
    [InlineData("not a mac")]
    [InlineData("AA-BB-CC-DD-EE")]              // too short
    [InlineData("AA-BB-CC-DD-EE-FF-GG")]        // too long
    [InlineData("AABBCCDDEEFF")]                // no separators
    [InlineData("ZZ-BB-CC-DD-EE-FF")]           // non-hex
    public void IsValid_RejectsGarbage(string s)
    {
        MacAddressBindings.IsValid(s).Should().BeFalse();
    }

    private sealed class TestPaths : IAppPaths, IDisposable
    {
        private readonly string _root;
        public TestPaths()
        {
            _root = Path.Combine(Path.GetTempPath(),
                "bromure-mac-bind-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(_root);
        }
        public string AppDataRoot => _root;
        public string MachineDataRoot => _root;
        public string ProfilesDirectory => Path.Combine(_root, "p");
        public string TracesDirectory => Path.Combine(_root, "t");
        public string ImagesDirectory => Path.Combine(_root, "i");
        public string SessionsDirectory => Path.Combine(_root, "s");
        public string ResourcesDirectory => Path.Combine(_root, "r");
        public string EnsureDirectory(string p) { Directory.CreateDirectory(p); return p; }
        public void Dispose() { try { Directory.Delete(_root, recursive: true); } catch (IOException) { } }
    }
}
