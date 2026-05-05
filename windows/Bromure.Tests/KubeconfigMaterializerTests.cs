using Bromure.AC.Core.Model;
using Bromure.AC.Mitm.Pki;
using FluentAssertions;
using Xunit;

namespace Bromure.Tests;

public class KubeconfigMaterializerTests
{
    [Fact]
    public void Materialize_BearerToken_ProducesSwapEntryAndYaml()
    {
        var profile = new Profile
        {
            Name = "Test",
            Kubeconfigs = new()
            {
                new KubeconfigEntry
                {
                    Name = "prod",
                    ServerUrl = "https://k8s.example.com:6443",
                    Auth = new KubeBearerToken { Token = "real-token-secret" },
                    RequireApproval = true,
                },
            },
        };
        var bromureCa = "-----BEGIN CERTIFICATE-----\nzz==\n-----END CERTIFICATE-----";
        var result = new KubeconfigMaterializer().Materialize(profile, bromureCa);

        result.Yaml.Should().Contain("apiVersion: v1");
        result.Yaml.Should().Contain("- name: prod");
        result.Yaml.Should().Contain("server: https://k8s.example.com:6443");
        result.BearerSwaps.Should().HaveCount(1);
        result.BearerSwaps[0].RealToken.Should().Be("real-token-secret");
        result.BearerSwaps[0].FakeToken.Should().NotBe("real-token-secret");
        result.BearerSwaps[0].ConsentCredentialId.Should().StartWith("kube:");
    }

    [Fact]
    public void Materialize_ExecPlugin_QueuesExecContext()
    {
        var profile = new Profile
        {
            Kubeconfigs = new()
            {
                new KubeconfigEntry
                {
                    Name = "aws-eks",
                    ServerUrl = "https://eks.us-east-1.example.com",
                    Auth = new KubeExecPlugin
                    {
                        Command = "aws-iam-authenticator",
                        Args = new() { "token", "-i", "prod" },
                        RefreshSeconds = 600,
                    },
                },
            },
        };
        var result = new KubeconfigMaterializer().Materialize(profile, "ca");
        result.ExecContexts.Should().HaveCount(1);
        result.ExecContexts[0].Command.Should().Be("aws-iam-authenticator");
        result.ExecContexts[0].Args.Should().Equal("token", "-i", "prod");
        result.ExecContexts[0].RefreshSeconds.Should().Be(600);
    }

    [Fact]
    public void Materialize_NoKubeconfigs_YamlStillValid()
    {
        var profile = new Profile { Name = "empty" };
        var result = new KubeconfigMaterializer().Materialize(profile, "ca");
        result.BearerSwaps.Should().BeEmpty();
        result.ClientIdentities.Should().BeEmpty();
        result.Yaml.Should().Contain("apiVersion: v1");
    }
}
