// macos-source: Sources/AgentCoding/Mitm/TraceStore.swift @ 5768a9d918d1
using System.Globalization;
using System.Text.Json;
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

    private readonly object _lock = new();
    private readonly SqliteConnection _connection;
    private long _appendCount;
    private readonly Dictionary<Guid, long> _bodyBytesPerSession = new();

    public string RootDirectory { get; }
    public int RingCapacity { get; set; } = 5000;

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
            if (!requestBody.IsEmpty)
            {
                added += WriteBody(record, BodyKind.Request, requestBody, encryptor);
            }
            if (!responseBody.IsEmpty)
            {
                added += WriteBody(record, BodyKind.Response, responseBody, encryptor);
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

    public IReadOnlyList<TraceRecord> Recent(int limit = 5000)
    {
        lock (_lock)
        {
            var output = new List<TraceRecord>(Math.Min(limit, RingCapacity));
            using var cmd = _connection.CreateCommand();
            cmd.CommandText = "SELECT * FROM traces ORDER BY timestamp_utc DESC LIMIT $limit";
            cmd.Parameters.AddWithValue("$limit", Math.Min(limit, RingCapacity));
            using var reader = cmd.ExecuteReader();
            while (reader.Read()) output.Add(ReadRecord(reader));
            return output;
        }
    }

    public byte[]? LoadBody(TraceRecord record, BodyKind kind, IBodyEncryptor? encryptor = null)
    {
        if (!record.BodyStored) return null;
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

    private int WriteBody(TraceRecord record, BodyKind kind, ReadOnlySpan<byte> data, IBodyEncryptor? enc)
    {
        var path = BodyPath(record, kind);
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var sealed_ = enc?.Encrypt(data) ?? data.ToArray();
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

    public void Dispose() => _connection.Dispose();

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
