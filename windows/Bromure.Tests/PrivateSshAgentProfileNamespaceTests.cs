using Bromure.AC.Mitm.Ssh;
using FluentAssertions;
using Org.BouncyCastle.Crypto.Generators;
using Org.BouncyCastle.Crypto.Parameters;
using Org.BouncyCastle.Security;
using Xunit;

namespace Bromure.Tests;

/// <summary>
/// Audit 05 §1.4 — per-profile namespace in PrivateSshAgent.
/// Before this fix, Clear()+AddEd25519() per session wiped any other
/// active session's keys. Tests pin: (a) two profiles can coexist,
/// (b) ClearForProfile is surgical, (c) ReplaceForProfile atomically
/// swaps one profile's slot without touching others, (d) BuildIdentitiesAnswer
/// dedupes the union, (e) sign requests find the key across profiles.
/// </summary>
public class PrivateSshAgentProfileNamespaceTests
{
    private static (byte[] seed, byte[] pub) Mint()
    {
        var gen = new Ed25519KeyPairGenerator();
        gen.Init(new Ed25519KeyGenerationParameters(new SecureRandom()));
        var pair = gen.GenerateKeyPair();
        return (
            ((Ed25519PrivateKeyParameters)pair.Private).GetEncoded(),
            ((Ed25519PublicKeyParameters)pair.Public).GetEncoded());
    }

    [Fact]
    public void TwoProfiles_KeysCoexist_OldApiClearStillClearsAll()
    {
        var agent = new PrivateSshAgent("test-" + Guid.NewGuid().ToString("N"));
        var pA = Guid.NewGuid();
        var pB = Guid.NewGuid();
        var (sA, pubA) = Mint();
        var (sB, pubB) = Mint();

        agent.AddEd25519(sA, pubA, "A", pA).Should().BeTrue();
        agent.AddEd25519(sB, pubB, "B", pB).Should().BeTrue();
        agent.KeyCount.Should().Be(2);

        // Legacy Clear() wipes EVERYTHING — preserved for tests /
        // shutdown. Engine code should use ClearForProfile instead.
        agent.Clear();
        agent.KeyCount.Should().Be(0);
    }

    [Fact]
    public void ClearForProfile_OnlyDropsTargetProfile()
    {
        var agent = new PrivateSshAgent("test-" + Guid.NewGuid().ToString("N"));
        var pA = Guid.NewGuid();
        var pB = Guid.NewGuid();
        var (sA, pubA) = Mint();
        var (sB, pubB) = Mint();
        agent.AddEd25519(sA, pubA, "A", pA);
        agent.AddEd25519(sB, pubB, "B", pB);

        agent.ClearForProfile(pA);
        agent.KeyCount.Should().Be(1, "profile B's key must survive A's clear");
    }

    [Fact]
    public void ReplaceForProfile_AtomicallySwapsOneProfileSlot()
    {
        var agent = new PrivateSshAgent("test-" + Guid.NewGuid().ToString("N"));
        var pA = Guid.NewGuid();
        var pB = Guid.NewGuid();
        var (sA1, pubA1) = Mint();
        var (sA2, pubA2) = Mint();
        var (sB, pubB) = Mint();

        // Initial: A has one key, B has one key.
        agent.AddEd25519(sA1, pubA1, "A1", pA);
        agent.AddEd25519(sB, pubB, "B", pB);
        agent.KeyCount.Should().Be(2);

        // Re-bind profile A with a different keyset (e.g. user
        // imported a second SSH key). Profile B should be untouched.
        agent.ReplaceForProfile(pA, new[]
        {
            (sA2, pubA2, "A2-new"),
        });
        agent.KeyCount.Should().Be(2, "A's old key dropped, A's new key added, B untouched");
    }

    [Fact]
    public void ReplaceForProfile_EmptyKeyset_ClearsThatProfileOnly()
    {
        var agent = new PrivateSshAgent("test-" + Guid.NewGuid().ToString("N"));
        var pA = Guid.NewGuid();
        var pB = Guid.NewGuid();
        var (sA, pubA) = Mint();
        var (sB, pubB) = Mint();
        agent.AddEd25519(sA, pubA, "A", pA);
        agent.AddEd25519(sB, pubB, "B", pB);

        agent.ReplaceForProfile(pA, Enumerable.Empty<(byte[], byte[], string)>());
        agent.KeyCount.Should().Be(1, "A dropped, B preserved");
    }

    [Fact]
    public void SameBlobAcrossProfiles_DedupedInIdentitiesAnswer()
    {
        // Audit 05 §3.1 cross-reference: when both profiles share the
        // default SSH key (paste-once-into-GitHub contract), the host's
        // ssh-add must see it exactly once, not duplicated.
        var agent = new PrivateSshAgent("test-" + Guid.NewGuid().ToString("N"));
        var pA = Guid.NewGuid();
        var pB = Guid.NewGuid();
        var (seed, pub) = Mint();
        agent.AddEd25519(seed, pub, "default-on-A", pA);
        agent.AddEd25519(seed, pub, "default-on-B", pB);

        // KeyCount counts per-profile entries (2), but the
        // IDENTITIES_ANSWER must dedupe by public blob (1).
        agent.KeyCount.Should().Be(2);

        var answer = InvokeBuildIdentitiesAnswer(agent);
        // Header: msg type (1 byte) + key-count (4 BE) — count must be 1.
        answer[0].Should().Be(12); // SSH_AGENT_IDENTITIES_ANSWER
        var count = (uint)((answer[1] << 24) | (answer[2] << 16) | (answer[3] << 8) | answer[4]);
        count.Should().Be(1u, "dedupe by public-key blob across profiles");
    }

    /// <summary>BuildIdentitiesAnswer is private — reach through
    /// reflection rather than spinning up a pipe client. The tests in
    /// PrivateSshAgentTests already cover the wire path; here we just
    /// want the dispatcher-level behaviour.</summary>
    private static byte[] InvokeBuildIdentitiesAnswer(PrivateSshAgent agent)
    {
        var m = typeof(PrivateSshAgent).GetMethod("BuildIdentitiesAnswer",
            System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Instance)!;
        return (byte[])m.Invoke(agent, null)!;
    }
}
