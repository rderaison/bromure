using Bromure.AC.Mitm.Trace;
using FluentAssertions;
using Xunit;

namespace Bromure.Tests;

public class TraceStoreTests
{
    private static TraceRecord MakeRecord(Guid? sessionId = null) => new(
        Id: Guid.NewGuid(),
        SessionId: sessionId ?? Guid.NewGuid(),
        ProfileId: Guid.NewGuid(),
        Timestamp: DateTimeOffset.UtcNow,
        Host: "api.anthropic.com",
        Port: 443,
        Method: "POST",
        Path: "/v1/messages",
        StatusCode: 200,
        RequestBytes: 256,
        ResponseBytes: 1024,
        LatencyMs: 42.0,
        Swaps: new[]
        {
            new SwapEntry("Authorization", "brm-...abcd", "sk-a...wxyz"),
        },
        Leaks: Array.Empty<LeakEntry>(),
        BodyStored: false,
        IsConversation: true);

    [Fact]
    public void Record_RoundTripsThroughSqlite()
    {
        using var tmp = new TempDir();
        using var store = new TraceStore(tmp.Path);
        var rec = MakeRecord();
        store.Record(rec);

        var recent = store.Recent(limit: 10);
        recent.Should().HaveCount(1);
        recent[0].Should().BeEquivalentTo(rec, opts => opts
            .ComparingByMembers<TraceRecord>()
            .Using<DateTimeOffset>(c =>
                c.Subject.UtcDateTime.Should().BeCloseTo(c.Expectation.UtcDateTime, TimeSpan.FromMilliseconds(10)))
            .WhenTypeIs<DateTimeOffset>());
    }

    [Fact]
    public void Recent_ReturnsNewestFirst()
    {
        using var tmp = new TempDir();
        using var store = new TraceStore(tmp.Path);

        var older = MakeRecord() with { Timestamp = DateTimeOffset.UtcNow.AddSeconds(-10) };
        var newer = MakeRecord() with { Timestamp = DateTimeOffset.UtcNow };
        store.Record(older);
        store.Record(newer);

        var recent = store.Recent(limit: 10);
        recent.Should().HaveCount(2);
        recent[0].Id.Should().Be(newer.Id);
        recent[1].Id.Should().Be(older.Id);
    }

    private sealed class TempDir : IDisposable
    {
        public string Path { get; }
        public TempDir()
        {
            Path = System.IO.Path.Combine(System.IO.Path.GetTempPath(),
                "bromure-tests-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(Path);
        }
        public void Dispose()
        {
            try { Directory.Delete(Path, recursive: true); } catch (IOException) { }
        }
    }
}
