// macos-source: Sources/AgentCoding/Mitm/TraceStore.swift @ 5768a9d918d1
using System.Globalization;
using System.Text.Json;
using System.Threading.Channels;
using Microsoft.Data.Sqlite;

namespace Bromure.AC.Mitm.Trace;

/// <summary>
/// Process-lifetime sink for <see cref="TraceRecord"/>s emitted by the
/// MITM proxy. Mirrors the macOS <c>TraceStore</c> contract but persists
/// to a SQLite WAL database (per WIN32_AC_PLAN §4 "TraceStore SQLite
/// schema").
///
/// <para>Layout under <see cref="RootDirectory"/>:</para>
/// <code>
///   traces/
///     trace.db                            ← WAL-mode SQLite
///     bodies/&lt;sessionId&gt;/&lt;recordId&gt;.{req,res}.enc
/// </code>
///
/// <para>Caps (matching macOS):</para>
/// <list type="bullet">
///   <item>Per-session bodies total ≤ 100 MB (drops oldest body files first).</item>
///   <item>Whole <c>traces/</c> dir ≤ 5 GB (drops oldest sessions).</item>
/// </list>
/// </summary>
public sealed class TraceStore : IDisposable
{
    public const long PerSessionBodyCap = 100L * 1024 * 1024;
    public const long TotalDirCap = 5L * 1024 * 1024 * 1024;
    private const int CleanupInterval = 200;

    // _lock protects the SQLite connection (it serializes writes
    // even with WAL mode) AND _bodyBytesPerSession. Only the drain
    // task touches these now, so contention is gone from the
    // proxy hot path — audit 06 §1.7.
    private readonly object _lock = new();
    private readonly SqliteConnection _connection;
    private long _appendCount;
    private readonly Dictionary<Guid, long> _bodyBytesPerSession = new();

    // Audit 06 §1.3 + §1.7: in-memory ring that's updated
    // SYNCHRONOUSLY on Record() so Recent() returns just-written
    // records without waiting on the disk drain. Falls through to
    // SQL only when the caller asks for more than RingCapacity.
    private readonly object _ringLock = new();
    private readonly LinkedList<TraceRecord> _ring = new();

    // Audit 06 §1.7: writes are off-thread. Record() snapshots
    // body buffers + enqueues; the drain task does SQL + file I/O
    // serially on a dedicated thread.
    private readonly Channel<WriteJob> _writes;
    private readonly Task _drainTask;
    private readonly CancellationTokenSource _shutdownCts = new();

    public string RootDirectory { get; }
    public int RingCapacity { get; set; } = 5000;

    private readonly record struct WriteJob(
        TraceRecord? Record,
        byte[]? RequestBody,
        byte[]? ResponseBody,
        IBodyEncryptor? Encryptor);

    public TraceStore(string rootDirectory)
    {
        RootDirectory = rootDirectory;
        Directory.CreateDirectory(rootDirectory);
        Directory.CreateDirectory(Path.Combine(rootDirectory, "bodies"));

        var dbPath = Path.Combine(rootDirectory, "trace.db");
        _connection = new SqliteConnection($"Data Source={dbPath};Cache=Shared");
        _connection.Open();

        ExecNonQuery("PRAGMA journal_mode=WAL;");
        ExecNonQuery("PRAGMA synchronous=NORMAL;");
        ExecNonQuery(@"
            CREATE TABLE IF NOT EXISTS traces (
                id              TEXT PRIMARY KEY,
                session_id      TEXT NOT NULL,
                profile_id      TEXT NOT NULL,
                timestamp_utc   TEXT NOT NULL,
                host            TEXT NOT NULL,
                port            INTEGER NOT NULL,
                method          TEXT NOT NULL,
                path            TEXT NOT NULL,
                status_code     INTEGER NOT NULL,
                request_bytes   INTEGER NOT NULL,
                response_bytes  INTEGER NOT NULL,
                latency_ms      REAL NOT NULL,
                swaps_json      TEXT NOT NULL,
                leaks_json      TEXT NOT NULL,
                body_stored     INTEGER NOT NULL,
                is_conversation INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_traces_session ON traces(session_id);
            CREATE INDEX IF NOT EXISTS idx_traces_ts ON traces(timestamp_utc);
            CREATE INDEX IF NOT EXISTS idx_traces_host ON traces(host);
        ");

        _writes = Channel.CreateUnbounded<WriteJob>(new UnboundedChannelOptions
        {
            SingleReader = true,
            SingleWriter = false,
            AllowSynchronousContinuations = false,
        });
        _drainTask = Task.Run(DrainLoopAsync);
    }

    /// <summary>
    /// Add a record + persist. Body data is optional — pass null when the
    /// level/host doesn't authorize body capture.
    /// </summary>
    public void Record(
        TraceRecord record,
        ReadOnlySpan<byte> requestBody = default,
        ReadOnlySpan<byte> responseBody = default,
        IBodyEncryptor? encryptor = null)
    {
        // Update the in-memory ring synchronously so Recent() sees
        // the record IMMEDIATELY, even before the disk write lands.
        // Cap to RingCapacity by evicting the oldest entry.
        lock (_ringLock)
        {
            _ring.AddLast(record);
            while (_ring.Count > RingCapacity)
            {
                _ring.RemoveFirst();
            }
        }
        // Snapshot the body spans BEFORE returning to the caller —
        // they're ReadOnlySpan<byte> which can't cross the channel
        // boundary anyway, and the caller's backing buffer may be
        // reused/freed once we return.
        var reqCopy = requestBody.IsEmpty ? null : requestBody.ToArray();
        var resCopy = responseBody.IsEmpty ? null : responseBody.ToArray();
        // TryWrite always succeeds for an unbounded channel.
        _writes.Writer.TryWrite(new WriteJob(record, reqCopy, resCopy, encryptor));
    }

    /// <summary>Block until all currently-queued writes have been
    /// committed to SQLite + body files. Tests call this between
    /// <see cref="Record"/> and any direct SQLite query so they
    /// observe a consistent on-disk state.</summary>
    public void Flush()
    {
        // Tracer trick: enqueue a sentinel that completes a TCS when
        // the drain task processes it. Because the channel is
        // single-reader and FIFO, every job written before the
        // sentinel has already been drained when the TCS resolves.
        var tcs = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        _writes.Writer.TryWrite(new WriteJob(
            Record: null,
            RequestBody: null,
            ResponseBody: null,
            Encryptor: new FlushSentinel(tcs)));
        tcs.Task.Wait();
    }

    private sealed class FlushSentinel : IBodyEncryptor
    {
        public readonly TaskCompletionSource Tcs;
        public FlushSentinel(TaskCompletionSource tcs) => Tcs = tcs;
        public byte[] Encrypt(ReadOnlySpan<byte> p) => throw new NotSupportedException();
        public byte[] Decrypt(ReadOnlySpan<byte> c) => throw new NotSupportedException();
    }

    public IReadOnlyList<TraceRecord> Recent(int limit = 5000)
    {
        // Ring is updated synchronously on Record(), so the recent
        // newest-first slice is available immediately even when
        // SQLite hasn't drained yet. Limit is capped at RingCapacity
        // (same as before) — older history would require a SQL fetch.
        var ringSize = Math.Min(limit, RingCapacity);
        lock (_ringLock)
        {
            // Snapshot in reverse-insertion order. Ties on Timestamp
            // are broken by insertion order (newer-inserted wins).
            var snapshot = new List<TraceRecord>(Math.Min(ringSize, _ring.Count));
            for (var node = _ring.Last; node is not null && snapshot.Count < ringSize; node = node.Previous)
            {
                snapshot.Add(node.Value);
            }
            // Stable sort by Timestamp DESC — matches the SQL
            // ORDER BY semantics for callers that mix records with
            // varying timestamps.
            snapshot.Sort((a, b) => b.Timestamp.CompareTo(a.Timestamp));
            return snapshot;
        }
    }

    /// <summary>Direct SQL query for traces older than the in-memory
    /// ring. Forces a flush first so the SQL state is current.</summary>
    public IReadOnlyList<TraceRecord> RecentFromDisk(int limit = 5000)
    {
        Flush();
        lock (_lock)
        {
            var output = new List<TraceRecord>(limit);
            using var cmd = _connection.CreateCommand();
            cmd.CommandText = "SELECT * FROM traces ORDER BY timestamp_utc DESC LIMIT $limit";
            cmd.Parameters.AddWithValue("$limit", limit);
            using var reader = cmd.ExecuteReader();
            while (reader.Read()) output.Add(ReadRecord(reader));
            return output;
        }
    }

    private async Task DrainLoopAsync()
    {
        // Channel.ReadAllAsync handles cancellation by completing the
        // sequence when the writer is completed. We Complete() it
        // from Dispose() to signal end-of-stream.
        await foreach (var job in _writes.Reader.ReadAllAsync().ConfigureAwait(false))
        {
            // Flush sentinel — signal the waiting Flush() caller.
            if (job.Encryptor is FlushSentinel s)
            {
                s.Tcs.TrySetResult();
                continue;
            }
            try { ProcessWriteJob(job); }
            catch (Exception) { /* never let one bad record kill the loop */ }
        }
    }

    private void ProcessWriteJob(WriteJob job)
    {
        if (job.Record is null) return; // sentinel — already handled in DrainLoopAsync
        var record = job.Record;
        lock (_lock)
        {
            using var cmd = _connection.CreateCommand();
            cmd.CommandText = @"
                INSERT OR REPLACE INTO traces VALUES
                ($id, $session, $profile, $ts, $host, $port, $method, $path,
                 $sc, $rb, $rsb, $lat, $swaps, $leaks, $bs, $conv)";
            cmd.Parameters.AddWithValue("$id", record.Id.ToString("D"));
            cmd.Parameters.AddWithValue("$session", record.SessionId.ToString("D"));
            cmd.Parameters.AddWithValue("$profile", record.ProfileId.ToString("D"));
            cmd.Parameters.AddWithValue("$ts", record.Timestamp.UtcDateTime.ToString("O", CultureInfo.InvariantCulture));
            cmd.Parameters.AddWithValue("$host", record.Host);
            cmd.Parameters.AddWithValue("$port", record.Port);
            cmd.Parameters.AddWithValue("$method", record.Method);
            cmd.Parameters.AddWithValue("$path", record.Path);
            cmd.Parameters.AddWithValue("$sc", record.StatusCode);
            cmd.Parameters.AddWithValue("$rb", record.RequestBytes);
            cmd.Parameters.AddWithValue("$rsb", record.ResponseBytes);
            cmd.Parameters.AddWithValue("$lat", record.LatencyMs);
            cmd.Parameters.AddWithValue("$swaps", JsonSerializer.Serialize(record.Swaps));
            cmd.Parameters.AddWithValue("$leaks", JsonSerializer.Serialize(record.Leaks));
            cmd.Parameters.AddWithValue("$bs", record.BodyStored ? 1 : 0);
            cmd.Parameters.AddWithValue("$conv", record.IsConversation ? 1 : 0);
            cmd.ExecuteNonQuery();

            var added = 0;
            if (job.RequestBody is not null)
            {
                added += WriteBody(record, BodyKind.Request, job.RequestBody, job.Encryptor);
            }
            if (job.ResponseBody is not null)
            {
                added += WriteBody(record, BodyKind.Response, job.ResponseBody, job.Encryptor);
            }

            if (added > 0)
            {
                if (!_bodyBytesPerSession.TryGetValue(record.SessionId, out var total))
                {
                    total = 0;
                }
                total += added;
                _bodyBytesPerSession[record.SessionId] = total;
                if (total > PerSessionBodyCap)
                {
                    EvictOldestBodiesInSession(record.SessionId, total);
                }
            }

            _appendCount++;
            if (_appendCount % CleanupInterval == 0)
            {
                EvictOldestSessionsIfOverTotalCap();
            }
        }
    }

    public byte[]? LoadBody(TraceRecord record, BodyKind kind, IBodyEncryptor? encryptor = null)
    {
        if (!record.BodyStored) return null;
        // The body write is async via the drain queue; flush so we
        // can observe writes that were enqueued before this call.
        // Tracer/UI callers always want "what's on disk right now",
        // and the small extra latency is fine outside the proxy hot
        // path (LoadBody isn't on the request-handling thread).
        Flush();
        var path = BodyPath(record, kind);
        if (!File.Exists(path)) return null;
        var blob = File.ReadAllBytes(path);
        return encryptor is null ? blob : encryptor.Decrypt(blob);
    }

    private static TraceRecord ReadRecord(SqliteDataReader r)
    {
        var swaps = JsonSerializer.Deserialize<IReadOnlyList<SwapEntry>>(r.GetString(12)) ?? Array.Empty<SwapEntry>();
        var leaks = JsonSerializer.Deserialize<IReadOnlyList<LeakEntry>>(r.GetString(13)) ?? Array.Empty<LeakEntry>();
        return new TraceRecord(
            Id: Guid.Parse(r.GetString(0)),
            SessionId: Guid.Parse(r.GetString(1)),
            ProfileId: Guid.Parse(r.GetString(2)),
            Timestamp: DateTimeOffset.Parse(r.GetString(3), CultureInfo.InvariantCulture),
            Host: r.GetString(4),
            Port: r.GetInt32(5),
            Method: r.GetString(6),
            Path: r.GetString(7),
            StatusCode: r.GetInt32(8),
            RequestBytes: r.GetInt32(9),
            ResponseBytes: r.GetInt32(10),
            LatencyMs: r.GetDouble(11),
            Swaps: swaps,
            Leaks: leaks,
            BodyStored: r.GetInt64(14) != 0,
            IsConversation: r.GetInt64(15) != 0);
    }

    private int WriteBody(TraceRecord record, BodyKind kind, byte[] data, IBodyEncryptor? enc)
    {
        var path = BodyPath(record, kind);
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var sealed_ = enc?.Encrypt(data) ?? data;
        File.WriteAllBytes(path, sealed_);
        return sealed_.Length;
    }

    private string BodyPath(TraceRecord record, BodyKind kind)
    {
        var suffix = kind == BodyKind.Request ? "req" : "res";
        return Path.Combine(
            RootDirectory, "bodies", record.SessionId.ToString("D"),
            $"{record.Id:D}.{suffix}.enc");
    }

    private void EvictOldestBodiesInSession(Guid sessionId, long currentTotal)
    {
        var dir = Path.Combine(RootDirectory, "bodies", sessionId.ToString("D"));
        if (!Directory.Exists(dir)) return;
        var files = Directory.EnumerateFiles(dir)
            .Select(f => new FileInfo(f))
            .OrderBy(f => f.LastWriteTimeUtc)
            .ToList();
        var total = currentTotal;
        foreach (var fi in files)
        {
            if (total <= PerSessionBodyCap) break;
            try { fi.Delete(); total -= fi.Length; }
            catch (IOException) { }
        }
        _bodyBytesPerSession[sessionId] = total;
    }

    private void EvictOldestSessionsIfOverTotalCap()
    {
        var bodiesRoot = Path.Combine(RootDirectory, "bodies");
        if (!Directory.Exists(bodiesRoot)) return;
        var sessionDirs = Directory.EnumerateDirectories(bodiesRoot)
            .Select(d => new DirectoryInfo(d))
            .OrderBy(d => d.LastWriteTimeUtc)
            .ToList();
        long total = sessionDirs.Sum(SizeOf);
        var idx = 0;
        while (total > TotalDirCap && idx < sessionDirs.Count)
        {
            var dir = sessionDirs[idx];
            var size = SizeOf(dir);
            try { dir.Delete(recursive: true); total -= size; }
            catch (IOException) { }
            idx++;
        }
    }

    private static long SizeOf(DirectoryInfo dir)
    {
        if (!dir.Exists) return 0;
        long sum = 0;
        foreach (var f in dir.EnumerateFiles("*", SearchOption.AllDirectories))
        {
            sum += f.Length;
        }
        return sum;
    }

    private void ExecNonQuery(string sql)
    {
        using var cmd = _connection.CreateCommand();
        cmd.CommandText = sql;
        cmd.ExecuteNonQuery();
    }

    public void Dispose()
    {
        // Complete the channel so the drain loop exits its
        // ReadAllAsync, then wait for it to finish writing whatever
        // was already enqueued. Without this, in-flight Records get
        // lost on app close.
        try { _writes.Writer.TryComplete(); } catch { }
        try { _drainTask.Wait(TimeSpan.FromSeconds(5)); } catch { }
        _shutdownCts.Cancel();
        _connection.Dispose();
        _shutdownCts.Dispose();
    }

    public enum BodyKind { Request, Response }
}

/// <summary>
/// Optional plug-in for sealing body bytes at rest. macOS uses
/// AES-GCM with the SecretsVault master key. Windows would do the
/// same — this seam lets the trace store be tested without a real key.
/// </summary>
public interface IBodyEncryptor
{
    byte[] Encrypt(ReadOnlySpan<byte> plaintext);
    byte[] Decrypt(ReadOnlySpan<byte> ciphertext);
}
