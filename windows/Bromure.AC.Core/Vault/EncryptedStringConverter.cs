using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Bromure.AC.Core.Vault;

/// <summary>
/// JsonConverter that transparently encrypts string properties at-rest
/// in <c>profile.json</c>. Audit 01 §1 / §10 §13.
///
/// <para><b>Read.</b> If the JSON token starts with
/// <c>"vault:v1:&lt;base64&gt;"</c>, decrypt it via
/// <see cref="SecretsCryptoGateway.Decrypt"/> and return the UTF-8
/// plaintext. Otherwise return the JSON string verbatim — that's a
/// legacy plaintext profile.json from before the vault wiring; the
/// next save will rewrite it encrypted.</para>
///
/// <para><b>Write.</b> If the gateway's encrypt delegate is wired and
/// the value is non-empty, prepend the marker + base64 of the AES-GCM
/// ciphertext. If the gateway is not wired (tests, ad-hoc tools),
/// write plaintext so the JSON stays inspectable. Null and empty
/// strings always round-trip as-is.</para>
///
/// <para>The marker is intentionally human-readable so a developer
/// opening profile.json doesn't mistake an encrypted blob for
/// corrupt data.</para>
/// </summary>
public sealed class EncryptedStringConverter : JsonConverter<string?>
{
    public override string? Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        if (reader.TokenType == JsonTokenType.Null) return null;
        if (reader.TokenType != JsonTokenType.String)
        {
            throw new JsonException($"Expected string for encrypted field, got {reader.TokenType}");
        }
        var raw = reader.GetString();
        if (string.IsNullOrEmpty(raw)) return raw;
        if (!raw.StartsWith(SecretsCryptoGateway.Prefix, StringComparison.Ordinal))
        {
            // Legacy plaintext or written by a host where the vault
            // wasn't wired. Return verbatim; the next Save() will
            // rewrite encrypted if the gateway is now wired.
            return raw;
        }
        var decrypt = SecretsCryptoGateway.Decrypt;
        if (decrypt is null)
        {
            // We can SEE this is encrypted but have no way to unwrap
            // it (tests / tools that haven't initialised the vault).
            // Surface a clear empty rather than the opaque marker so
            // a tool printing the value doesn't claim the secret IS
            // the literal "vault:v1:abc…".
            return "";
        }
        try
        {
            var blob = Convert.FromBase64String(raw[SecretsCryptoGateway.Prefix.Length..]);
            var plain = decrypt(blob);
            return Encoding.UTF8.GetString(plain);
        }
        catch
        {
            // Don't let a corrupt blob crash profile loading. The
            // user can re-enter the secret in the editor; the broken
            // entry round-trips as empty.
            return "";
        }
    }

    public override void Write(Utf8JsonWriter writer, string? value, JsonSerializerOptions options)
    {
        if (value is null) { writer.WriteNullValue(); return; }
        if (value.Length == 0) { writer.WriteStringValue(""); return; }
        // Idempotency: if the caller hands us an already-wrapped
        // value (round-trip from a Read above), don't double-wrap.
        if (value.StartsWith(SecretsCryptoGateway.Prefix, StringComparison.Ordinal))
        {
            writer.WriteStringValue(value);
            return;
        }
        var encrypt = SecretsCryptoGateway.Encrypt;
        if (encrypt is null)
        {
            writer.WriteStringValue(value);
            return;
        }
        var blob = encrypt(Encoding.UTF8.GetBytes(value));
        writer.WriteStringValue(SecretsCryptoGateway.Prefix + Convert.ToBase64String(blob));
    }
}
