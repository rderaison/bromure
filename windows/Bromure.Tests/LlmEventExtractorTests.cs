using System.Text;
using Bromure.Cloud;
using FluentAssertions;
using Xunit;

namespace Bromure.Tests;

public class LlmEventExtractorTests
{
    [Theory]
    [InlineData("Read", true)]
    [InlineData("ReadFile", true)]
    [InlineData("read_file", true)]
    [InlineData("Glob", true)]
    [InlineData("Bash", false)]
    [InlineData("Write", false)]
    public void IsFileReadTool_MatchesAcrossProviderConventions(string tool, bool expected)
        => LlmEventExtractor.IsFileReadTool(tool).Should().Be(expected);

    [Theory]
    [InlineData("Write", true)]
    [InlineData("Edit", true)]
    [InlineData("apply_patch", true)]
    [InlineData("MultiEdit", true)]
    [InlineData("Read", false)]
    public void IsFileWriteTool_MatchesAcrossProviderConventions(string tool, bool expected)
        => LlmEventExtractor.IsFileWriteTool(tool).Should().Be(expected);

    [Fact]
    public void ExtractPath_PullsFilePathFromAnthropicShape()
    {
        var input = "{\"file_path\":\"/tmp/foo.txt\",\"old_string\":\"a\",\"new_string\":\"b\"}";
        LlmEventExtractor.ExtractPath(input).Should().Be("/tmp/foo.txt");
    }

    [Fact]
    public void ExtractPath_FallsThroughKeyAliases()
    {
        LlmEventExtractor.ExtractPath("{\"path\":\"/x\"}").Should().Be("/x");
        LlmEventExtractor.ExtractPath("{\"target_file\":\"/y\"}").Should().Be("/y");
    }

    [Fact]
    public void ExtractCommand_UnwrapsBashLcShape()
    {
        var input = "{\"command\":[\"bash\",\"-lc\",\"echo hi && ls\"]}";
        LlmEventExtractor.ExtractCommand(input).Should().Be("echo hi && ls");
    }

    [Fact]
    public void ExtractCommand_FallsBackToString()
    {
        LlmEventExtractor.ExtractCommand("{\"command\":\"ls -la\"}").Should().Be("ls -la");
    }

    [Fact]
    public void ParseAnthropicTokens_TopLevelUsage()
    {
        var body = """{"id":"msg_x","usage":{"input_tokens":12,"output_tokens":34,"cache_read_input_tokens":5}}""";
        var t = LlmEventExtractor.ParseAnthropicTokens(Encoding.UTF8.GetBytes(body));
        t.InputTokens.Should().Be(12);
        t.OutputTokens.Should().Be(34);
        t.CacheReadInputTokens.Should().Be(5);
    }

    [Fact]
    public void ParseAnthropicTokens_StreamingDeltasTakeLatestOutputCount()
    {
        var body =
            "data: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":10,\"output_tokens\":1}}}\n"
          + "data: {\"type\":\"message_delta\",\"usage\":{\"output_tokens\":42}}\n";
        var t = LlmEventExtractor.ParseAnthropicTokens(Encoding.UTF8.GetBytes(body));
        t.InputTokens.Should().Be(10);
        t.OutputTokens.Should().Be(42);
    }

    [Fact]
    public void ParseOpenAiTokens_MapsPromptCompletionCachedTokens()
    {
        var body = """
            {"usage":{"prompt_tokens":50,"completion_tokens":80,
                      "prompt_tokens_details":{"cached_tokens":12}}}
            """;
        var t = LlmEventExtractor.ParseOpenAiTokens(Encoding.UTF8.GetBytes(body));
        t.InputTokens.Should().Be(50);
        t.OutputTokens.Should().Be(80);
        t.CacheReadInputTokens.Should().Be(12);
    }
}
