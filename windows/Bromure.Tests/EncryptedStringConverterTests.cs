using System.Text.Json;
using Bromure.AC.Core.Vault;
using FluentAssertions;
using Xunit;

namespace Bromure.Tests;

/// <summary>
/// Unit coverage for <see cref="EncryptedStringConverter"/>. The
/// converter routes through <see cref="SecretsCryptoGateway"/>; tests
/// stub the gateway with a deterministic XOR transform so the
/// roundtrip is purely behavioural — no DPAPI / vault dependency.
///
/// <para>Each test resets the gateway in a finally block; they share
/// process state through the static delegates, so concurrent execution
/// would race. Xunit defaults to per-class serial dispatch, which is
/// what we rely on here.</para>
/// </summary>
public class EncryptedStringConverterTests : IDisposable
{
    private sealed class Box
    {
        [System.Text.Json.Serialization.JsonConverter(typeof(EncryptedStringConverter))]
        public string? Secret { get; set; }
    }

    public EncryptedStringConverterTests()
    {
        // Toy obfuscation — every byte XOR'd with 0x5A. Not crypto;
        // the converter doesn't care what the gateway does as long
        // as encrypt(decrypt(x)) == x.
        SecretsCryptoGateway.Encrypt = bytes => bytes.Select(b => (byte)(b ^ 0x5A)).ToArray();
        SecretsCryptoGateway.Decrypt = bytes => bytes.Select(b => (byte)(b ^ 0x5A)).ToArray();
    }

    public void Dispose()
    {
        SecretsCryptoGateway.Encrypt = null;
        SecretsCryptoGateway.Decrypt = null;
    }

    [Fact]
    public void Write_wraps_value_with_vault_marker()
    {
        var json = JsonSerializer.Serialize(new Box { Secret = "hunter2" });
        json.Should().Contain("\"vault:v1:");
        json.Should().NotContain("hunter2");
    }

    [Fact]
    public void Read_unwraps_marker_back_to_plaintext()
    {
        var json = JsonSerializer.Serialize(new Box { Secret = "hunter2" });
        var roundTripped = JsonSerializer.Deserialize<Box>(json);
        roundTripped!.Secret.Should().Be("hunter2");
    }

    [Fact]
    public void Read_passes_legacy_plaintext_through_unchanged()
    {
        // Simulates a profile.json saved before the vault wiring.
        var legacy = "{\"Secret\":\"legacyPlaintextToken\"}";
        var parsed = JsonSerializer.Deserialize<Box>(legacy);
        parsed!.Secret.Should().Be("legacyPlaintextToken");
    }

    [Fact]
    public void Write_passes_null_and_empty_through_unchanged()
    {
        var nullJson = JsonSerializer.Serialize(new Box { Secret = null });
        nullJson.Should().Be("{\"Secret\":null}");
        var emptyJson = JsonSerializer.Serialize(new Box { Secret = "" });
        emptyJson.Should().Be("{\"Secret\":\"\"}");
    }

    [Fact]
    public void Write_does_not_double_wrap_already_encrypted_value()
    {
        var first = JsonSerializer.Serialize(new Box { Secret = "k" });
        var box = JsonSerializer.Deserialize<Box>(first);
        // Simulate a code path that forgot to decrypt and is round-
        // tripping the wrapped value as-is (defensive — shouldn't
        // happen via the model, but the converter must be idempotent).
        box!.Secret = first[(first.IndexOf("\"vault:v1:", StringComparison.Ordinal) + 1)..^2];
        var roundTripped = JsonSerializer.Serialize(box);
        // The second serialization should still contain ONE marker, not two.
        var occurrences = roundTripped.Split("vault:v1:").Length - 1;
        occurrences.Should().Be(1);
    }

    [Fact]
    public void Read_when_gateway_unset_returns_empty_for_encrypted_blob()
    {
        var serialized = JsonSerializer.Serialize(new Box { Secret = "hunter2" });
        // Forget how to decrypt (simulate a stripped tool that has
        // the marker but no key access).
        SecretsCryptoGateway.Encrypt = null;
        SecretsCryptoGateway.Decrypt = null;
        var parsed = JsonSerializer.Deserialize<Box>(serialized);
        parsed!.Secret.Should().Be("");  // safe fallback, not the literal marker
    }

    [Fact]
    public void Read_garbage_blob_falls_through_to_empty_string()
    {
        var garbage = "{\"Secret\":\"vault:v1:not-valid-base64!!!\"}";
        var parsed = JsonSerializer.Deserialize<Box>(garbage);
        parsed!.Secret.Should().Be("");
    }
}
