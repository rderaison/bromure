using System.Text;
using Bromure.AC.Mitm.Swap;
using FluentAssertions;
using Xunit;

namespace Bromure.Tests;

public class AhoCorasickTests
{
    [Fact]
    public void Scan_FindsAllPatternsInOnePass()
    {
        var patterns = new[] { "he", "she", "his", "hers" }
            .Select(p => Encoding.ASCII.GetBytes(p))
            .ToArray();
        var ac = new AhoCorasick(patterns);

        var hits = ac.Scan(Encoding.ASCII.GetBytes("ushers"));
        hits.Should().Contain(new[] { 0, 1, 3 });
    }

    [Fact]
    public void Scan_EmptyPatternsDropped()
    {
        var patterns = new[] { Array.Empty<byte>(), "a"u8.ToArray() };
        var ac = new AhoCorasick(patterns);
        ac.PatternCount.Should().Be(1);
        ac.Scan("aaa"u8).Should().Equal(1);
    }

    [Fact]
    public void Scan_DuplicatePatternsIgnoredBeyondFirst()
    {
        var patterns = new[] { "abc"u8.ToArray(), "abc"u8.ToArray(), "xyz"u8.ToArray() };
        var ac = new AhoCorasick(patterns);
        ac.PatternCount.Should().Be(2);
        ac.Scan("abcxyz"u8).Should().Contain(new[] { 0, 2 });
    }

    [Fact]
    public void Scan_NoMatchReturnsEmpty()
    {
        var ac = new AhoCorasick(new[] { "needle"u8.ToArray() });
        ac.Scan("haystack haystack haystack"u8).Should().BeEmpty();
    }
}
