#!/usr/bin/env bash
# Signs the packaged Windows app and builds its installers, on macOS or Linux,
# from out/ (run `node scripts/package.mjs win32` first):
#   scripts/installer-win.sh [--require-sign] [x64,arm64]
#
# The signing is Bromure Sidecar's, step for step (sidecar/scripts/installer.sh
# is the reference — keep the two in line): Authenticode with SSL.com eSigner
# through jsign, by sidecar/scripts/esign.sh. Tools are provisioned when
# missing (Homebrew on macOS, apt on Linux): makensis (NSIS 3.08+), and for
# signing a JDK, osslsigncode (verification) and jsign 7.6 (downloaded once,
# SHA-256 checked; JSIGN_JAR overrides).
#
# Signing is on when all four of ESIGNER_USERNAME, ESIGNER_PASSWORD,
# ESIGNER_CREDENTIAL_ID and ESIGNER_TOTP_SECRET are set; unsigned when none is
# (SmartScreen warns on first run). Some but not all is an error, and so is
# none with --require-sign. ESIGNER_KEYSTORE picks the eSigner service
# (https://cs-try.ssl.com: the sandbox, whose test certificates don't chain to
# a trusted root; only there is that tolerated).
#
# Signed, in order, per architecture: the app's executables in
# out/Bromure Client-win32-<arch>/ (then the portable .zip is written again, so
# it holds the signed ones), the uninstaller (before NSIS embeds it) and the
# setup. Every signed file is verified (signature and timestamp), and
# out/win-SHA256SUMS is written last so it matches the signed bytes. The
# secrets never reach a command line or a log: jsign reads them from the
# environment.
set -euo pipefail
cd "$(dirname "$0")/.."
root=$PWD
out=$root/out
esign=$root/../sidecar/scripts/esign.sh

require_sign=0
if [ "${1:-}" = "--require-sign" ]; then require_sign=1; shift; fi
IFS=', ' read -r -a archs <<<"${*:-x64,arm64}"
for a in "${archs[@]}"; do
  case "$a" in x64|arm64) ;; *) echo "unknown architecture '$a' (x64, arm64)" >&2; exit 1 ;; esac
done

JSIGN_VERSION=7.6
JSIGN_SHA256=6cf58aa080e7ff82656f320cff8d4a3bff30408df8766806dcba3740dd839fa5

die() { echo "ERROR: $*" >&2; exit 1; }
sha256() { if command -v sha256sum >/dev/null; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }
blank() { [ -z "${1//[[:space:]]/}" ]; }

command -v node >/dev/null || die "node is not on PATH"
version=$(node -p "require('./package.json').version")
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "package.json version must be X.Y.Z, got '$version'"

# --- What signing needs -------------------------------------------------------
vars=(ESIGNER_USERNAME ESIGNER_PASSWORD ESIGNER_CREDENTIAL_ID ESIGNER_TOTP_SECRET)
present=0; missing=()
for v in "${vars[@]}"; do
  if blank "${!v:-}"; then missing+=("$v"); else present=$((present + 1)); fi
done
if [ $present -gt 0 ] && [ ${#missing[@]} -gt 0 ]; then
  die "signing is half-configured: ${missing[*]} not set (set all of ${vars[*]}, or none for an unsigned build)"
fi
sign=0; [ $present -eq ${#vars[@]} ] && sign=1
[ $sign -eq 0 ] && [ $require_sign -eq 1 ] && die "--require-sign: signing isn't configured (set ${vars[*]})"
# jsign splits the eSigner storepass "<username>|<password>" on the first
# "|" (7.6: split("\\|", 2)): the password may contain one, the username not.
[ $sign -eq 1 ] && [[ "$ESIGNER_USERNAME" == *"|"* ]] && die "ESIGNER_USERNAME contains '|', which jsign uses to separate it from the password"
sandbox=0
if [ $sign -eq 1 ] && [[ "${ESIGNER_KEYSTORE:-}" == *cs-try.* ]]; then
  sandbox=1; echo "WARNING: SANDBOX build ($ESIGNER_KEYSTORE): test signatures, not for release" >&2
fi

for a in "${archs[@]}"; do
  [ -f "$out/Bromure Client-win32-$a/Bromure Client.exe" ] || die "no packaged app in $out/Bromure Client-win32-$a/ (run node scripts/package.mjs win32 first)"
done
[ $sign -eq 0 ] || [ -f "$esign" ] || die "$esign is missing"

# --- Tools ---------------------------------------------------------------------
provision() { # provision <command> <brew formula> <apt package>
  command -v "$1" >/dev/null && return 0
  echo "installing $1…"
  if [ "$(uname -s)" = Darwin ]; then
    command -v brew >/dev/null || die "$1 is missing and Homebrew isn't installed"
    HOMEBREW_NO_AUTO_UPDATE=1 brew install "$2" >/dev/null
  elif command -v apt-get >/dev/null; then
    local s=""; [ "$(id -u)" -ne 0 ] && s="sudo -n"
    $s apt-get install -y --no-install-recommends "$3" >/dev/null || die "$1 is missing: apt-get install $3 failed (needs root or passwordless sudo)"
  else
    die "$1 is missing and there's no brew or apt-get to install it"
  fi
  command -v "$1" >/dev/null || die "$1 still isn't on the PATH after installing $2/$3"
}

provision makensis makensis nsis
nsis_version=$(makensis -VERSION | sed 's/^v//')
echo "makensis $nsis_version"

if [ $sign -eq 1 ]; then
  # !uninstfinalize (signing the embedded uninstaller) needs NSIS 3.08+.
  awk -v v="$nsis_version" 'BEGIN { split(v, p, "."); exit !(p[1] > 3 || (p[1] == 3 && p[2] + 0 >= 8)) }' ||
    die "makensis $nsis_version is older than 3.08 (needed to sign the uninstaller)"
  provision osslsigncode osslsigncode osslsigncode
  provision zip zip zip
  if [ -z "${JAVA:-}" ]; then
    if command -v java >/dev/null && java -version >/dev/null 2>&1; then
      JAVA=java   # (macOS's /usr/bin/java stub fails -version without a JDK)
    elif [ "$(uname -s)" = Darwin ]; then
      command -v brew >/dev/null || die "no Java and no Homebrew to install one"
      [ -x "$(brew --prefix openjdk)/bin/java" ] || { echo "installing openjdk…"; HOMEBREW_NO_AUTO_UPDATE=1 brew install openjdk >/dev/null; }
      JAVA="$(brew --prefix openjdk)/bin/java"
    else
      provision java openjdk default-jre-headless; JAVA=java
    fi
  fi
  "$JAVA" -version >/dev/null 2>&1 || die "Java doesn't run ($JAVA): set JAVA to a JDK 11+'s java"
  export JAVA
  if [ -z "${JSIGN_JAR:-}" ]; then
    JSIGN_JAR="${XDG_CACHE_HOME:-$HOME/.cache}/bromure/jsign-$JSIGN_VERSION.jar"
    if [ ! -f "$JSIGN_JAR" ]; then
      mkdir -p "$(dirname "$JSIGN_JAR")"
      curl -fsSL -o "$JSIGN_JAR.part" "https://github.com/ebourg/jsign/releases/download/$JSIGN_VERSION/jsign-$JSIGN_VERSION.jar"
      mv "$JSIGN_JAR.part" "$JSIGN_JAR"
    fi
  fi
  [ -f "$JSIGN_JAR" ] || die "jsign not found at $JSIGN_JAR"
  got=$(sha256 "$JSIGN_JAR" | cut -d' ' -f1)
  [ "$got" = "$JSIGN_SHA256" ] || { rm -f "$JSIGN_JAR"; die "jsign $JSIGN_VERSION SHA-256 mismatch ($got); removed"; }
  export JSIGN_JAR ESIGNER_CREDENTIAL_ID ESIGNER_TOTP_SECRET
  [ -n "${ESIGNER_KEYSTORE:-}" ] && export ESIGNER_KEYSTORE
  # The one secret assembled here; cleared on exit, whatever happens.
  trap 'unset JSIGN_STOREPASS' EXIT
  export JSIGN_STOREPASS="$ESIGNER_USERNAME|$ESIGNER_PASSWORD"
  # installer-win.mjs hands it to makensis (-DSIGN_SCRIPT): the uninstaller
  # and the setup are signed as NSIS writes them.
  export BROMURE_SIGN_SCRIPT="$esign"
else
  unset BROMURE_SIGN_SCRIPT
  echo "WARNING: unsigned build (no ESIGNER_* credentials): SmartScreen will warn on first run" >&2
fi

# Signature AND timestamp; only a sandbox build may have an untrusted root.
verify() {
  local f=$1 out_ ca=""
  for c in /etc/ssl/cert.pem /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt; do
    [ -f "$c" ] && { ca=$c; break; }
  done
  if out_=$(osslsigncode verify ${ca:+-CAfile "$ca"} ${ca:+-TSA-CAfile "$ca"} -in "$f" 2>&1); then
    :
  elif [ $sandbox -eq 1 ] && grep -qi "Signature verification: ok" <<<"$out_"; then
    echo "  (sandbox: untrusted root tolerated)"
  else
    echo "$out_" | tail -20 >&2; die "signature check failed: $f"
  fi
  grep -qi "timestamp" <<<"$out_" || { echo "$out_" | tail -20 >&2; die "signature check failed: $f has no timestamp"; }
  echo "verified: $f ($(grep -m1 -i 'Subject:' <<<"$out_" | sed 's/^[[:space:]]*//'))"
}

# --- Sign the app, then the installers ----------------------------------------
# The executables @electron/packager laid out (Bromure Client.exe; any other
# .exe a later Electron ships next to it). Electron's DLLs stay as shipped,
# like electron-builder's default.
if [ $sign -eq 1 ]; then
  for a in "${archs[@]}"; do
    base="Bromure Client-win32-$a"
    for f in "$out/$base"/*.exe; do bash "$esign" "$f"; done
    # package.mjs zipped the unsigned app: write the portable .zip again.
    rm -f "$out/$base.zip"
    ( cd "$out" && zip -qryX "$base.zip" "$base" -x '*/.DS_Store' '*/._*' )
  done
fi
node scripts/installer-win.mjs "$(IFS=,; echo "${archs[*]}")"
installers=()
for a in "${archs[@]}"; do installers+=("$out/BromureClient-$version-$a-setup.exe"); done
if [ $sign -eq 1 ]; then
  for a in "${archs[@]}"; do
    for f in "$out/Bromure Client-win32-$a"/*.exe; do verify "$f"; done
  done
  for f in "${installers[@]}"; do verify "$f"; done
fi

# --- Checksums, after signing --------------------------------------------------
( cd "$out" && sha256 BromureClient-"$version"-*-setup.exe "Bromure Client-win32-"*.zip | sed 's/ \*/  /' > win-SHA256SUMS && cat win-SHA256SUMS )
