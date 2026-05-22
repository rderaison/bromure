using Bromure.AC.Core.Model;
using FluentAssertions;
using Xunit;

namespace Bromure.Tests;

/// <summary>
/// Coverage for the IsUsable / IsValidName predicates added to bring
/// the credential records to parity with the macOS Profile.swift
/// helpers. Audit 01 flagged these as missing — without them the
/// editor can't gate save-buttons and the engine can't quietly skip
/// half-filled rows.
/// </summary>
public class CredentialValidationTests
{
    [Fact]
    public void GitHttpsCredential_IsUsable_RequiresAllThreeFields()
    {
        var full = new GitHttpsCredential { Host = "github.com", Username = "u", Token = "t" };
        full.IsUsable.Should().BeTrue();
        new GitHttpsCredential { Host = "", Username = "u", Token = "t" }.IsUsable.Should().BeFalse();
        new GitHttpsCredential { Host = "h", Username = "", Token = "t" }.IsUsable.Should().BeFalse();
        new GitHttpsCredential { Host = "h", Username = "u", Token = "" }.IsUsable.Should().BeFalse();
        new GitHttpsCredential { Host = "  ", Username = "u", Token = "t" }.IsUsable.Should().BeFalse(
            "whitespace-only host doesn't count");
    }

    [Fact]
    public void ManualToken_IsUsable_RequiresValue()
    {
        new ManualToken { Value = "real-secret-stuff" }.IsUsable.Should().BeTrue();
        new ManualToken { Value = "" }.IsUsable.Should().BeFalse();
        new ManualToken { Value = "   " }.IsUsable.Should().BeFalse();
    }

    [Fact]
    public void DockerRegistryCredential_IsUsable_RequiresAllThreeFields()
    {
        new DockerRegistryCredential { Host = "h", Username = "u", Password = "p" }.IsUsable.Should().BeTrue();
        new DockerRegistryCredential { Username = "u", Password = "p" }.IsUsable.Should().BeFalse();
        new DockerRegistryCredential { Host = "h", Password = "p" }.IsUsable.Should().BeFalse();
        new DockerRegistryCredential { Host = "h", Username = "u" }.IsUsable.Should().BeFalse();
    }

    [Fact]
    public void AwsCredentialsConfig_IsUsable_StaticKeysNeedsBoth()
    {
        new AwsCredentialsConfig
        {
            AuthMode = AwsAuthMode.StaticKeys,
            AccessKeyId = "AKIA…",
            SecretAccessKey = "secret",
        }.IsUsable.Should().BeTrue();
        new AwsCredentialsConfig
        {
            AuthMode = AwsAuthMode.StaticKeys,
            AccessKeyId = "AKIA…",
        }.IsUsable.Should().BeFalse();
        new AwsCredentialsConfig
        {
            AuthMode = AwsAuthMode.StaticKeys,
            SecretAccessKey = "secret",
        }.IsUsable.Should().BeFalse();
    }

    [Fact]
    public void AwsCredentialsConfig_IsUsable_SsoNeedsProfile()
    {
        new AwsCredentialsConfig
        {
            AuthMode = AwsAuthMode.Sso,
            SsoProfile = "engineering",
        }.IsUsable.Should().BeTrue();
        new AwsCredentialsConfig { AuthMode = AwsAuthMode.Sso }.IsUsable.Should().BeFalse();
    }

    [Fact]
    public void ImportedSshKey_IsUsable_RequiresOpenSshPemMarker()
    {
        new ImportedSshKey { PrivateKeyPem = "-----BEGIN OPENSSH PRIVATE KEY-----\nb64base64\n-----END OPENSSH PRIVATE KEY-----" }
            .IsUsable.Should().BeTrue();
        new ImportedSshKey { PrivateKeyPem = "" }.IsUsable.Should().BeFalse();
        new ImportedSshKey { PrivateKeyPem = "-----BEGIN RSA PRIVATE KEY-----\n..." }
            .IsUsable.Should().BeFalse("we only support OpenSSH-format ed25519 today");
    }

    [Theory]
    [InlineData("FOO", true)]
    [InlineData("foo_bar", true)]
    [InlineData("_LEADING_UNDERSCORE", true)]
    [InlineData("PATH123", true)]
    [InlineData("", false)]
    [InlineData("1FOO", false)]
    [InlineData("FOO-BAR", false)]
    [InlineData("FOO BAR", false)]
    [InlineData("FOO=", false)]
    [InlineData("FOO.BAR", false)]
    public void EnvironmentVariable_IsValidName_MatchesPosixGrammar(string name, bool expected)
    {
        EnvironmentVariable.IsValidEnvVarName(name).Should().Be(expected);
        new EnvironmentVariable { Name = name }.IsValidName.Should().Be(expected);
    }
}
