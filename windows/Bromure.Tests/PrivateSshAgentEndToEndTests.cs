using System.Buffers.Binary;
using System.IO.Pipes;
using System.Text;
using Bromure.AC.Core.Model;
using Bromure.AC.Core.Ssh;
using Bromure.AC.Mitm.Consent;
using Bromure.AC.Mitm.Engine;
using Bromure.AC.Mitm.Ssh;
using Bromure.Platform;
using FluentAssertions;
using Xunit;

namespace Bromure.Tests;

/// <summary>
/// Real end-to-end coverage for the SSH agent. The earlier
/// MitmEngineBindingsTests only asserted that SshAgent.KeysFor
/// returned the loaded keys — which would pass even with the
/// named-pipe listener dead. This test actually:
/// <list type="number">
///   <item>Starts <see cref="MitmEngine.StartAsync"/> so PrivateSshAgent
///   binds the named pipe;</item>
///   <item>Calls ApplyProfileBindingsAsync to load a key;</item>
///   <item>Connects to the pipe with the OpenSSH agent wire protocol;</item>
///   <item>Sends SSH_AGENTC_REQUEST_IDENTITIES;</item>
///   <item>Parses the response and asserts our key is in the answer.</item>
/// </list>
/// If any link in that chain breaks, <c>ssh-add -l</c> would fail in
/// the real app — this test would fail too.
/// </summary>
public class PrivateSshAgentEndToEndTests
{
    private const string PipeName = "bromure-ac-ssh-agent";
    private const byte SSH_AGENTC_REQUEST_IDENTITIES = 11;
    private const byte SSH_AGENT_IDENTITIES_ANSWER = 12;

    [Fact]
    public async Task EnginePipe_ServesIdentitiesAnswer_AfterApplyProfileBindings()
    {
        using var paths = new TestPaths();
        await using var engine = new MitmEngine(paths, paths.Secrets, new AlwaysAllowSessionDialogPresenter());
        // Start the engine: this is what makes the named-pipe
        // listener live. The earlier wiring DID set keys, but
        // without StartAsync there was no pipe at all.
        await engine.StartAsync();

        var profile = new Profile { Id = Guid.NewGuid(), Name = "p" };
        ProfileSshKey.EnsureExists(paths, profile);
        await engine.ApplyProfileBindingsAsync(profile);

        // Give the pipe-server's async accept loop a moment to
        // become connectable. The accept loop starts on a Task.Run
        // inside StartAsync; on cold machines the first connect
        // sometimes races.
        var identities = await ConnectAndListIdentitiesAsync(TimeSpan.FromSeconds(5));
        identities.Should().NotBeEmpty("the auto-generated profile key must be served on the pipe");
        identities[0].Type.Should().Be("ssh-ed25519");
        identities[0].PublicKey.Length.Should().Be(32);
        identities[0].Comment.Should().StartWith("bromure-ac-");
    }

    [Fact]
    public async Task EnginePipe_ServesUnionAcrossSimultaneousProfiles()
    {
        // Audit 05 §1.4 fix: PrivateSshAgent is now per-profile
        // namespaced. Two profiles bound back-to-back BOTH have
        // their keys on the pipe — the host's `ssh-add -l` sees
        // the union. Previous behavior (Clear() before populate)
        // dropped profile1's key when profile2 was bound.
        using var paths = new TestPaths();
        await using var engine = new MitmEngine(paths, paths.Secrets, new AlwaysAllowSessionDialogPresenter());
        await engine.StartAsync();

        var profile1 = new Profile { Id = Guid.NewGuid(), Name = "p1" };
        ProfileSshKey.EnsureExists(paths, profile1);
        await engine.ApplyProfileBindingsAsync(profile1);

        var profile2 = new Profile { Id = Guid.NewGuid(), Name = "p2" };
        ProfileSshKey.EnsureExists(paths, profile2);
        await engine.ApplyProfileBindingsAsync(profile2);

        var identities = await ConnectAndListIdentitiesAsync(TimeSpan.FromSeconds(5));
        // Two distinct keys (one per profile) — both profiles
        // simultaneously active means the host sees both keys.
        identities.Should().HaveCount(2);
        identities.Select(i => i.Comment).Should().OnlyHaveUniqueItems();
    }

    [Fact]
    public async Task EnginePipe_UnregisterDropsOnlyThatProfilesKey()
    {
        // Audit 05 §1.4: when profile1 is unregistered, profile2's
        // key must remain available on the pipe.
        using var paths = new TestPaths();
        await using var engine = new MitmEngine(paths, paths.Secrets, new AlwaysAllowSessionDialogPresenter());
        await engine.StartAsync();

        var profile1 = new Profile { Id = Guid.NewGuid(), Name = "p1" };
        ProfileSshKey.EnsureExists(paths, profile1);
        await engine.ApplyProfileBindingsAsync(profile1);

        var profile2 = new Profile { Id = Guid.NewGuid(), Name = "p2" };
        ProfileSshKey.EnsureExists(paths, profile2);
        await engine.ApplyProfileBindingsAsync(profile2);

        await engine.UnregisterAsync(profile1.Id);

        var identities = await ConnectAndListIdentitiesAsync(TimeSpan.FromSeconds(5));
        identities.Should().HaveCount(1, "profile2's key survives profile1 unregister");
    }

    private static async Task<IReadOnlyList<IdentityEntry>> ConnectAndListIdentitiesAsync(TimeSpan timeout)
    {
        var deadline = DateTime.UtcNow + timeout;
        Exception? last = null;
        while (DateTime.UtcNow < deadline)
        {
            try
            {
                using var client = new NamedPipeClientStream(".", PipeName,
                    PipeDirection.InOut, PipeOptions.Asynchronous);
                await client.ConnectAsync((int)Math.Min(500, (deadline - DateTime.UtcNow).TotalMilliseconds + 1));

                // Send SSH_AGENTC_REQUEST_IDENTITIES.
                var msg = new byte[] { SSH_AGENTC_REQUEST_IDENTITIES };
                var lenBuf = new byte[4];
                BinaryPrimitives.WriteUInt32BigEndian(lenBuf, (uint)msg.Length);
                await client.WriteAsync(lenBuf);
                await client.WriteAsync(msg);
                await client.FlushAsync();

                var respLenBuf = await ReadExactAsync(client, 4);
                var respLen = (int)BinaryPrimitives.ReadUInt32BigEndian(respLenBuf);
                respLen.Should().BeGreaterThan(0).And.BeLessThan(256 * 1024);
                var resp = await ReadExactAsync(client, respLen);
                resp[0].Should().Be(SSH_AGENT_IDENTITIES_ANSWER, "agent must return IDENTITIES_ANSWER");

                var idx = 1;
                var count = (int)BinaryPrimitives.ReadUInt32BigEndian(resp.AsSpan(idx, 4));
                idx += 4;
                var entries = new List<IdentityEntry>(count);
                for (var i = 0; i < count; i++)
                {
                    var blob = ReadSshString(resp, ref idx);
                    var comment = Encoding.UTF8.GetString(ReadSshString(resp, ref idx));
                    var blobIdx = 0;
                    var typeBytes = ReadSshString(blob, ref blobIdx);
                    var type = Encoding.ASCII.GetString(typeBytes);
                    var pub = ReadSshString(blob, ref blobIdx);
                    entries.Add(new IdentityEntry(type, pub, comment));
                }
                return entries;
            }
            catch (TimeoutException ex) { last = ex; await Task.Delay(50); }
            catch (System.IO.IOException ex) { last = ex; await Task.Delay(50); }
        }
        throw new TimeoutException(
            $"Could not connect + parse IDENTITIES_ANSWER on \\\\.\\pipe\\{PipeName} within {timeout}: {last?.Message}");
    }

    private static async Task<byte[]> ReadExactAsync(System.IO.Stream s, int count)
    {
        var buf = new byte[count];
        var got = 0;
        while (got < count)
        {
            var n = await s.ReadAsync(buf.AsMemory(got, count - got));
            if (n == 0) throw new System.IO.EndOfStreamException();
            got += n;
        }
        return buf;
    }

    private static byte[] ReadSshString(byte[] buf, ref int idx)
    {
        var len = (int)BinaryPrimitives.ReadUInt32BigEndian(buf.AsSpan(idx, 4));
        idx += 4;
        var data = buf.AsSpan(idx, len).ToArray();
        idx += len;
        return data;
    }

    private sealed record IdentityEntry(string Type, byte[] PublicKey, string Comment);

    private sealed class TestPaths : IAppPaths, IDisposable
    {
        private readonly string _root;
        public InMemSecrets Secrets { get; } = new();
        public TestPaths()
        {
            _root = System.IO.Path.Combine(System.IO.Path.GetTempPath(),
                "bromure-ssh-e2e-" + Guid.NewGuid().ToString("N"));
            System.IO.Directory.CreateDirectory(_root);
        }
        public string AppDataRoot => _root;
        public string MachineDataRoot => _root;
        public string ProfilesDirectory => System.IO.Path.Combine(_root, "profiles");
        public string TracesDirectory => System.IO.Path.Combine(_root, "traces");
        public string ImagesDirectory => System.IO.Path.Combine(_root, "images");
        public string SessionsDirectory => System.IO.Path.Combine(_root, "sessions");
        public string ResourcesDirectory => System.IO.Path.Combine(_root, "resources");
        public string EnsureDirectory(string p) { System.IO.Directory.CreateDirectory(p); return p; }
        public void Dispose() { try { System.IO.Directory.Delete(_root, recursive: true); } catch (System.IO.IOException) { } }
    }

    private sealed class InMemSecrets : ISecretStore
    {
        private readonly Dictionary<string, string> _s = new();
        private readonly Dictionary<string, byte[]> _b = new();
        public void StoreSecret(string svc, string acct, string v) => _s[svc + "|" + acct] = v;
        public string? ReadSecret(string svc, string acct) => _s.GetValueOrDefault(svc + "|" + acct);
        public void DeleteSecret(string svc, string acct) => _s.Remove(svc + "|" + acct);
        public void StoreBlob(string n, ReadOnlySpan<byte> d, BlobScope s) => _b[s + "|" + n] = d.ToArray();
        public byte[]? ReadBlob(string n, BlobScope s) => _b.GetValueOrDefault(s + "|" + n);
        public void DeleteBlob(string n, BlobScope s) => _b.Remove(s + "|" + n);
    }
}
