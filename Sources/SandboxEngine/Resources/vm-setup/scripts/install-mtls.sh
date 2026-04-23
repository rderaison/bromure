#!/bin/sh
# install-mtls.sh — import a managed-profile mTLS client certificate into
# the chrome user's NSS database so Chromium can present it when a site
# requests a client cert.
#
# Runs at session start from config-agent.py, after the material has been
# dropped at /tmp/bromure/mtls/. The NSS db is created fresh every session
# (VMs are ephemeral; nothing persists across boots).
#
# Inputs:
#   /tmp/bromure/mtls/cert.pem   leaf client certificate (PEM)
#   /tmp/bromure/mtls/key.pem    leaf private key (PKCS#8 PEM)
#   /tmp/bromure/mtls/ca.pem     issuing CA certificate (PEM)
#
# The private key never touches the base image and is deleted from /tmp
# as soon as it's imported into NSS.

set -eu

MTLS_DIR="/tmp/bromure/mtls"
if [ ! -f "$MTLS_DIR/cert.pem" ] || [ ! -f "$MTLS_DIR/key.pem" ] || [ ! -f "$MTLS_DIR/ca.pem" ]; then
    exit 0
fi

NSS_DIR="/home/chrome/.pki/nssdb"
mkdir -p "$NSS_DIR"
chown -R chrome:chrome /home/chrome/.pki

# --empty-password + -f /dev/null keeps the db passphraseless so Chromium
# can open it non-interactively. Re-running on an existing db is a no-op.
su -s /bin/sh chrome -c "certutil -d sql:$NSS_DIR -N --empty-password" 2>/dev/null || true

# On re-runs (live cert rotation), delete any existing entries under
# our nicknames so pk12util / certutil -A don't complain about dupes
# or add a second copy alongside the old one. Errors ignored: on the
# very first run these don't exist yet.
su -s /bin/sh chrome -c "certutil -d sql:$NSS_DIR -D -n 'bromure-mtls'" 2>/dev/null || true
su -s /bin/sh chrome -c "certutil -d sql:$NSS_DIR -D -n 'bromure-ca'" 2>/dev/null || true

# pk12util only accepts PKCS#12 bundles, so combine cert + key into one.
P12="$MTLS_DIR/leaf.p12"
openssl pkcs12 -export \
    -out "$P12" \
    -inkey "$MTLS_DIR/key.pem" \
    -in "$MTLS_DIR/cert.pem" \
    -name "bromure-mtls" \
    -passout pass:
chown chrome:chrome "$P12"

# Trust anchor for server-side verification of our own CA (so the cert
# renders as valid in chrome://settings/certificates).
su -s /bin/sh chrome -c "certutil -d sql:$NSS_DIR -A -n 'bromure-ca' -t 'CT,,' -i $MTLS_DIR/ca.pem"

# Import the leaf + private key. -W '' matches the blank passphrase above.
su -s /bin/sh chrome -c "pk12util -d sql:$NSS_DIR -i $P12 -W ''"

# Scrub the PKCS#12 and the raw private key. The cert + CA can linger for
# debugging — they're public.
rm -f "$P12" "$MTLS_DIR/key.pem"

SUBJECT=$(openssl x509 -in "$MTLS_DIR/cert.pem" -noout -subject 2>/dev/null || echo "?")
echo "install-mtls.sh: imported leaf cert ($SUBJECT)" > /dev/hvc0 2>/dev/null || true
