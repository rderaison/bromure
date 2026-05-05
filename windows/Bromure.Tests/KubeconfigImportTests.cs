using System.Text;
using Bromure.AC.Core.Imports;
using FluentAssertions;
using Xunit;

namespace Bromure.Tests;

public class KubeconfigImportTests
{
    [Fact]
    public void Parse_BearerTokenContext_RoundTrips()
    {
        var ca = Convert.ToBase64String(Encoding.UTF8.GetBytes("CA-PEM"));
        var yaml = $"""
            apiVersion: v1
            kind: Config
            current-context: prod
            clusters:
              - name: prod
                cluster:
                  server: https://k8s.example.com
                  certificate-authority-data: {ca}
            users:
              - name: dev
                user:
                  token: abc.def.ghi
            contexts:
              - name: prod
                context:
                  cluster: prod
                  user: dev
                  namespace: web
            """;
        var entries = KubeconfigImport.Parse(yaml);
        entries.Should().HaveCount(1);
        entries[0].Name.Should().Be("prod");
        entries[0].ServerUrl.Should().Be("https://k8s.example.com");
        entries[0].Namespace.Should().Be("web");
        entries[0].CaCertPem.Should().Be("CA-PEM");
        entries[0].AuthSpec.Should().BeOfType<KubeconfigEntry.Auth.BearerTokenAuth>()
            .Which.Token.Should().Be("abc.def.ghi");
    }

    [Fact]
    public void Parse_CurrentContext_IsListedFirst()
    {
        var yaml = """
            apiVersion: v1
            kind: Config
            current-context: second
            clusters:
              - name: c1
                cluster:
                  server: https://1.example.com
              - name: c2
                cluster:
                  server: https://2.example.com
            users:
              - name: u1
                user:
                  token: t1
              - name: u2
                user:
                  token: t2
            contexts:
              - name: first
                context:
                  cluster: c1
                  user: u1
              - name: second
                context:
                  cluster: c2
                  user: u2
            """;
        var entries = KubeconfigImport.Parse(yaml);
        entries.Should().HaveCount(2);
        entries[0].Name.Should().Be("second");
        entries[1].Name.Should().Be("first");
    }

    [Fact]
    public void Parse_ExecPlugin_IsParsed()
    {
        var yaml = """
            apiVersion: v1
            kind: Config
            clusters:
              - name: prod
                cluster:
                  server: https://example.com
            users:
              - name: aws
                user:
                  exec:
                    command: aws-iam-authenticator
                    args:
                      - token
                      - -i
                      - prod
            contexts:
              - name: prod
                context:
                  cluster: prod
                  user: aws
            """;
        var entries = KubeconfigImport.Parse(yaml);
        entries.Should().HaveCount(1);
        var auth = entries[0].AuthSpec.Should().BeOfType<KubeconfigEntry.Auth.ExecPluginAuth>().Subject;
        auth.Command.Should().Be("aws-iam-authenticator");
        auth.Args.Should().Equal("token", "-i", "prod");
    }

    [Fact]
    public void Parse_Empty_Throws()
    {
        FluentActions.Invoking(() => KubeconfigImport.Parse(""))
            .Should().Throw<KubeconfigImport.ImportException>();
    }
}
