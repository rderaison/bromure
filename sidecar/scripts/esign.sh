#!/usr/bin/env bash
# Authenticode-signs one Windows file with SSL.com eSigner through jsign.
#   scripts/esign.sh <file>
# installer.sh calls it for the executables, and makensis (!finalize,
# !uninstfinalize) for the setup and the uninstaller it embeds. Everything
# comes from the environment installer.sh prepares: JAVA, JSIGN_JAR,
# ESIGNER_CREDENTIAL_ID, optional ESIGNER_KEYSTORE, and the secrets jsign
# reads itself (--storepass env:JSIGN_STOREPASS, --keypass
# env:ESIGNER_TOTP_SECRET), so none of them is ever on a command line.
#
# SSL.com accepted 8 back-to-back signatures on one OTP window (2026-11-19);
# if it starts rejecting, space the calls 30 s apart.
set -euo pipefail
f="${1:?usage: esign.sh <file>}"
: "${JSIGN_JAR:?}" "${ESIGNER_CREDENTIAL_ID:?}" "${JSIGN_STOREPASS:?}" "${ESIGNER_TOTP_SECRET:?}"
args=(--storetype ESIGNER
      --storepass env:JSIGN_STOREPASS
      --keypass env:ESIGNER_TOTP_SECRET
      --alias "$ESIGNER_CREDENTIAL_ID"
      --alg SHA-256
      --tsaurl http://ts.ssl.com --tsmode RFC3161
      --replace)
[ -n "${ESIGNER_KEYSTORE:-}" ] && args+=(--keystore "$ESIGNER_KEYSTORE")
echo "signing $f"
exec "${JAVA:-java}" -jar "$JSIGN_JAR" "${args[@]}" "$f"
