namespace Bromure.AC.Mitm.Aws;

/// <summary>
/// Real AWS signing material the host holds for a profile. The VM never
/// sees these — the resigner consumes them on the host.
/// </summary>
public sealed record AwsCredentials(
    string AccessKeyId,
    string SecretAccessKey,
    string SessionToken,
    bool RequireApproval = false)
{
    public bool IsUsable =>
        !string.IsNullOrWhiteSpace(AccessKeyId)
        && !string.IsNullOrWhiteSpace(SecretAccessKey);
}
