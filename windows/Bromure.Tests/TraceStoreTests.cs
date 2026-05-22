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
    public void Record_EncryptsBodyOnDisk_WhenEncryptorProvided()
    {
        using var tmp = new TempDir();
        using var store = new TraceStore(tmp.Path);
        var enc = new ReverseEncryptor();
        var rec = MakeRecord() with { BodyStored = true };
        var plaintext = "hello world"u8.ToArray();

        store.Record(rec, requestBody: plaintext, responseBody: ReadOnlySpan<byte>.Empty, encryptor: enc);
        // Audit 06 §1.7: writes are async. Tests that read the
        // bodies/ directory directly (i.e. not through LoadBody)
        // must flush explicitly.
        store.Flush();

        // The on-disk body file should be the reversed bytes (our fake encryption).
        var bodyDir = Path.Combine(tmp.Path, "bodies", rec.SessionId.ToString("D"));
        var bodyFile = Directory.EnumerateFiles(bodyDir).Single(f => f.EndsWith(".req.enc"));
        var raw = File.ReadAllBytes(bodyFile);
        raw.Should().Equal(plaintext.Reverse().ToArray());

        // LoadBody with the same encryptor unwraps to the original plaintext.
        var roundTrip = store.LoadBody(rec, TraceStore.BodyKind.Request, enc);
        roundTrip.Should().Equal(plaintext);
    }

    private sealed class ReverseEncryptor : IBodyEncryptor
    {
        public byte[] Encrypt(ReadOnlySpan<byte> plaintext)
        {
            var output = plaintext.ToArray();
            Array.Reverse(output);
            return output;
        }

        public byte[] Decrypt(ReadOnlySpan<byte> ciphertext)
        {
            var output = ciphertext.ToArray();
            Array.Reverse(output);
            return output;
        }
    }

    [Fact]
    public void LoadBody_RoundTrips_WithSameEncryptor()
    {
        using var tmp = new TempDir();
        using var store = new TraceStore(tmp.Path);
        var enc = new ReverseEncryptor();
        var rec = MakeRecord() with { BodyStored = true };
        var requestBytes = "request-blob"u8.ToArray();
        var responseBytes = "response-blob"u8.ToArray();

        store.Record(rec, requestBytes, responseBytes, enc);

        store.LoadBody(rec, TraceStore.BodyKind.Request, enc).Should().Equal(requestBytes);
        store.LoadBody(rec, TraceStore.BodyKind.Response, enc).Should().Equal(responseBytes);
    }

    [Fact]
    public void LoadBody_ReturnsNullWhenBodyNotStored()
    {
        using var tmp = new TempDir();
        using var store = new TraceStore(tmp.Path);
        var rec = MakeRecord() with { BodyStored = false };
        store.Record(rec);
        store.LoadBody(rec, TraceStore.BodyKind.Request).Should().BeNull();
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

    [Fact]
    public void Record_DoesNotBlockOnSqliteWrite()
    {
        // Audit 06 §1.7: writes are off-thread. The hot path
        // should not be paying SQLite mutex + body-write cost.
        // We can't measure SQLite directly, but: pumping 200
        // records through Record() with a deliberately slow
        // encryptor must complete in much less time than the
        // serial work would have taken (200 × ~50 ms = 10 s).
        using var tmp = new TempDir();
        using var store = new TraceStore(tmp.Path);
        var slow = new SlowEncryptor(perRecordSleepMs: 50);

        var sw = System.Diagnostics.Stopwatch.StartNew();
        for (int i = 0; i < 50; i++)
        {
            var rec = MakeRecord() with { BodyStored = true };
            store.Record(rec, "a"u8.ToArray(), "b"u8.ToArray(), slow);
        }
        sw.Stop();
        // Serial cost would be 50 × 100 ms (req + res) = ~5 s.
        // Async cost should be a small fraction since the proxy
        // thread just snapshots + enqueues.
        sw.ElapsedMilliseconds.Should().BeLessThan(2000,
            "the proxy hot path must not be blocked by per-record encryption + disk writes");

        // Sanity: when we flush, all 50 records DO land.
        store.Flush();
        store.Recent(limit: 100).Should().HaveCount(50);
    }

    [Fact]
    public void Record_RingReflectsWriteImmediately_BeforeFlush()
    {
        using var tmp = new TempDir();
        using var store = new TraceStore(tmp.Path);
        var rec = MakeRecord();
        store.Record(rec);
        // No Flush() — the ring is updated synchronously, so
        // Recent() must see the record without waiting.
        store.Recent(limit: 10).Should().HaveCount(1);
        store.Recent(limit: 10)[0].Id.Should().Be(rec.Id);
    }

    [Fact]
    public void Flush_BlocksUntilAllQueuedWritesLand()
    {
        using var tmp = new TempDir();
        using var store = new TraceStore(tmp.Path);
        var slow = new SlowEncryptor(perRecordSleepMs: 50);
        for (int i = 0; i < 5; i++)
        {
            store.Record(MakeRecord() with { BodyStored = true },
                "x"u8.ToArray(), "y"u8.ToArray(), slow);
        }
        store.Flush();
        // After Flush, RecentFromDisk reads SQL and finds all 5.
        store.RecentFromDisk(10).Should().HaveCount(5);
    }

    private sealed class SlowEncryptor : IBodyEncryptor
    {
        private readonly int _sleepMs;
        public SlowEncryptor(int perRecordSleepMs) => _sleepMs = perRecordSleepMs;
        public byte[] Encrypt(ReadOnlySpan<byte> plaintext)
        {
            System.Threading.Thread.Sleep(_sleepMs);
            return plaintext.ToArray();
        }
        public byte[] Decrypt(ReadOnlySpan<byte> ciphertext) => ciphertext.ToArray();
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
