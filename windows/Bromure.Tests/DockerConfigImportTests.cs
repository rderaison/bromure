using System.Text;
using Bromure.AC.Core.Imports;
using FluentAssertions;
using Xunit;

namespace Bromure.Tests;

public class DockerConfigImportTests
{
    private static byte[] Bytes(string s) => Encoding.UTF8.GetBytes(s);

    [Fact]
    public void Parse_DockerHubAlias_NormalisesToDockerIo()
    {
        var b64 = Convert.ToBase64String(Encoding.UTF8.GetBytes("alice:hunter2"));
        var json = $$"""
            {
              "auths": {
                "https://index.docker.io/v1/": { "auth": "{{b64}}" }
              }
            }
            """;
        var result = DockerConfigImport.Parse(Bytes(json));
        result.Entries.Should().HaveCount(1);
        result.Entries[0].Host.Should().Be("docker.io");
        result.Entries[0].Username.Should().Be("alice");
        result.Entries[0].Password.Should().Be("hunter2");
    }

    [Fact]
    public void Parse_PortAndPath_AreStrippedFromHost()
    {
        var b64 = Convert.ToBase64String(Encoding.UTF8.GetBytes("u:p"));
        var json = $$"""
            {
              "auths": {
                "myregistry.example.com:5000/v2": { "auth": "{{b64}}" }
              }
            }
            """;
        var result = DockerConfigImport.Parse(Bytes(json));
        result.Entries.Should().HaveCount(1);
        result.Entries[0].Host.Should().Be("myregistry.example.com");
    }

    [Fact]
    public void Parse_HelperManagedEntries_AreCounted()
    {
        var json = """
            {
              "credsStore": "desktop",
              "credHelpers": {
                "ghcr.io": "wincred",
                "myregistry.example.com": "wincred"
              }
            }
            """;
        var result = DockerConfigImport.Parse(Bytes(json));
        result.Entries.Should().BeEmpty();
        result.SkippedHelper.Should().Be(2);
    }

    [Fact]
    public void Parse_MissingAuthsAndNoHelpers_Throws()
    {
        var json = "{ \"foo\": 1 }";
        FluentActions.Invoking(() => DockerConfigImport.Parse(Bytes(json)))
            .Should().Throw<DockerConfigImport.ImportException>();
    }

    [Fact]
    public void Parse_MalformedJson_Throws()
    {
        FluentActions.Invoking(() => DockerConfigImport.Parse(Bytes("not json")))
            .Should().Throw<DockerConfigImport.ImportException>();
    }
}
