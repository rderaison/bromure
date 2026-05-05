using Bromure.AC.Mitm.SigV4;

namespace Bromure.AC.Mitm.Aws;

/// <summary>
/// Vends AWS signing credentials to <see cref="AwsResigner"/>. The real
/// implementation hosts an IMDSv2-shaped HTTP server inside the host
/// (port 169.254.170.2 in the guest, tunnelled via the proxy) so the
/// AWS SDK in the VM picks up creds without ever seeing the real ones.
/// </summary>
public interface IAwsCredentialServer
{
    Task<SigningMaterial> SigningMaterialAsync(Guid profileId, string scopeHint, CancellationToken ct);
}

public abstract record SigningMaterial
{
    public sealed record Material(SigV4Signer.Credentials Credentials) : SigningMaterial;
    public sealed record Denied : SigningMaterial;
    public sealed record Missing : SigningMaterial;
}
