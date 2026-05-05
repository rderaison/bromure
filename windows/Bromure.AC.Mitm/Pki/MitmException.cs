namespace Bromure.AC.Mitm.Pki;

/// <summary>
/// Direct port of <c>MitmError</c> from <c>BromureCA.swift</c>.
/// Discrete cases mirror the macOS enum so log lines line up across
/// platforms.
/// </summary>
public sealed class MitmException : Exception
{
    public MitmExceptionKind Kind { get; }

    public MitmException(MitmExceptionKind kind, string message, Exception? inner = null)
        : base(message, inner)
    {
        Kind = kind;
    }

    public static MitmException CertEncodingFailed(Exception? inner = null) =>
        new(MitmExceptionKind.CertEncodingFailed, "MITM: failed to DER-encode certificate", inner);

    public static MitmException KeyImportFailed(string detail, Exception? inner = null) =>
        new(MitmExceptionKind.KeyImportFailed, $"MITM: failed to import private key ({detail})", inner);

    public static MitmException IdentityCreationFailed(Exception? inner = null) =>
        new(MitmExceptionKind.IdentityCreationFailed, "MITM: failed to create SecIdentity", inner);

    public static MitmException TlsHandshakeFailed(string detail) =>
        new(MitmExceptionKind.TlsHandshakeFailed, $"MITM: TLS handshake failed ({detail})");

    public static MitmException MalformedHttpRequest(string detail) =>
        new(MitmExceptionKind.MalformedHttpRequest, $"MITM: malformed HTTP request ({detail})");

    public static MitmException UnexpectedTermination() =>
        new(MitmExceptionKind.UnexpectedTermination, "MITM: connection terminated mid-stream");

    public static MitmException UpstreamFailed(string detail) =>
        new(MitmExceptionKind.UpstreamFailed, $"MITM: upstream request failed ({detail})");
}

public enum MitmExceptionKind
{
    CertEncodingFailed,
    KeyImportFailed,
    IdentityCreationFailed,
    TlsHandshakeFailed,
    TlsReadFailed,
    TlsWriteFailed,
    MalformedHttpRequest,
    UnexpectedTermination,
    UpstreamFailed,
}
