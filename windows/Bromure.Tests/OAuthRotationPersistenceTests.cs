using Bromure.AC.Mitm.OAuth;
using Bromure.AC.Mitm.Swap;
using FluentAssertions;
using Xunit;

namespace Bromure.Tests;

/// <summary>
/// Audit 07 §4 recordRotation: when the OAuth rotation rewriter
/// extracts a fresh real token off /oauth/token, the host has to
/// persist it back onto the profile so the next session boot can
/// auto-seed without forcing a re-login. These tests pin the
/// rewriter→callback wire so the persistence path stays connected.
/// </summary>
public class OAuthRotationPersistenceTests
{
    [Fact]
    public void Rewriter_ClaudeRefresh_ExposesFreshReals()
    {
        // Build a fake POST /oauth/token response body with fresh
        // real tokens (sk-ant-oat01-… / sk-ant-ort01-…).
        var profileId = Guid.NewGuid();
        var swapper = new TokenSwapper(new Bromure.AC.Mitm.Consent.ConsentBroker(
            new AutoApproveConsent()));
        var realAccess = "sk-ant-oat01-" + new string('A', 80);
        var realRefresh = "sk-ant-ort01-" + new string('B', 80);
        var body = $@"{{""access_token"":""{realAccess}"",""refresh_token"":""{realRefresh}"",""token_type"":""Bearer"",""expires_in"":3600}}";
        var raw = BuildResponse(body);

        var result = OAuthRotationRewriter.Rewrite(raw, OAuthRotationProvider.Claude, profileId, swapper);

        result.NewReals.Should().NotBeNull();
        result.NewReals!.AccessToken.Should().Be(realAccess);
        result.NewReals.RefreshToken.Should().Be(realRefresh);
        result.NewReals.IdToken.Should().BeNull("Claude doesn't issue an id_token");
    }

    [Fact]
    public void Rewriter_CodexRefresh_ExposesFreshReals()
    {
        var profileId = Guid.NewGuid();
        var swapper = new TokenSwapper(new Bromure.AC.Mitm.Consent.ConsentBroker(
            new AutoApproveConsent()));
        // Codex tokens are JWT-shaped: three dot-separated
        // base64 segments. SubscriptionFakeMint.MintJwtFake refuses
        // to mint a fake from anything that doesn't fit.
        var realAccess = "eyJ" + new string('A', 50) + "." + new string('B', 50) + "." + new string('C', 50);
        var realRefresh = "rt_" + new string('D', 43) + "." + new string('E', 43);
        var realId = "eyJ" + new string('F', 50) + "." + new string('G', 50) + "." + new string('H', 50);
        var body = $@"{{""access_token"":""{realAccess}"",""refresh_token"":""{realRefresh}"",""id_token"":""{realId}""}}";
        var raw = BuildResponse(body);

        var result = OAuthRotationRewriter.Rewrite(raw, OAuthRotationProvider.Codex, profileId, swapper);

        result.NewReals.Should().NotBeNull();
        result.NewReals!.AccessToken.Should().Be(realAccess);
        result.NewReals.RefreshToken.Should().Be(realRefresh);
        result.NewReals.IdToken.Should().Be(realId);
    }

    [Fact]
    public void StoredOAuthTokens_SavedAt_RoundTripsViaJson()
    {
        // The audit 01 §2 SavedAt field needs to survive a JSON
        // round-trip — Profile gets serialized via ProfileStore on
        // every Save. Without this, the next-session check
        // "is this token fresh enough to auto-seed?" can't fire.
        var ts = new DateTimeOffset(2026, 5, 22, 12, 30, 0, TimeSpan.Zero);
        var src = new Bromure.AC.Core.Model.StoredOAuthTokens
        {
            AccessToken = "a",
            RefreshToken = "r",
            IdToken = "i",
            SavedAt = ts,
        };
        var json = System.Text.Json.JsonSerializer.Serialize(src);
        var back = System.Text.Json.JsonSerializer.Deserialize<Bromure.AC.Core.Model.StoredOAuthTokens>(json);

        back.Should().NotBeNull();
        back!.SavedAt.Should().Be(ts);
        back.AccessToken.Should().Be("a");
        back.RefreshToken.Should().Be("r");
        back.IdToken.Should().Be("i");
    }

    private static byte[] BuildResponse(string jsonBody)
    {
        var headers =
            "HTTP/1.1 200 OK\r\n" +
            "Content-Type: application/json\r\n" +
            $"Content-Length: {System.Text.Encoding.UTF8.GetByteCount(jsonBody)}\r\n" +
            "\r\n";
        var headerBytes = System.Text.Encoding.UTF8.GetBytes(headers);
        var bodyBytes = System.Text.Encoding.UTF8.GetBytes(jsonBody);
        var combined = new byte[headerBytes.Length + bodyBytes.Length];
        Buffer.BlockCopy(headerBytes, 0, combined, 0, headerBytes.Length);
        Buffer.BlockCopy(bodyBytes, 0, combined, headerBytes.Length, bodyBytes.Length);
        return combined;
    }

    private sealed class AutoApproveConsent : Bromure.AC.Mitm.Consent.IConsentDialogPresenter
    {
        public Task<Bromure.AC.Mitm.Consent.ConsentBroker.Decision> AskAsync(
            string profileName, string credentialDisplayName, string scopeHint, CancellationToken ct)
            => Task.FromResult(Bromure.AC.Mitm.Consent.ConsentBroker.Decision.Allow5Min);
    }
}
