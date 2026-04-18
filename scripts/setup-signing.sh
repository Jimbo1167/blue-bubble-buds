#!/bin/bash
# One-time setup: create a self-signed code-signing identity for Blue Bubble Buds.
# After this runs, every `build-app.sh` will sign with the same identity, and
# the Full Disk Access grant you give to the app will PERSIST across rebuilds.
#
# Run:  bash scripts/setup-signing.sh

set -euo pipefail

IDENTITY_NAME="Blue Bubble Buds Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
WORK_DIR="$(mktemp -d)"
trap "rm -rf $WORK_DIR" EXIT

echo "==> Checking for existing identity"
if security find-identity -v -p codesigning | grep -q "$IDENTITY_NAME"; then
    echo "Identity '$IDENTITY_NAME' already exists. Nothing to do."
    security find-identity -v -p codesigning | grep "$IDENTITY_NAME"
    exit 0
fi

echo "==> Generating self-signed code-signing certificate"

cat > "$WORK_DIR/openssl.cnf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions    = v3_req
prompt             = no

[ dn ]
CN = $IDENTITY_NAME

[ v3_req ]
basicConstraints       = critical, CA:FALSE
keyUsage               = critical, digitalSignature
extendedKeyUsage       = critical, codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$WORK_DIR/signing.key" \
    -out    "$WORK_DIR/signing.crt" \
    -config "$WORK_DIR/openssl.cnf" 2>/dev/null

# Bundle into a PKCS#12 for import
openssl pkcs12 -export -legacy \
    -inkey "$WORK_DIR/signing.key" \
    -in "$WORK_DIR/signing.crt" \
    -out "$WORK_DIR/signing.p12" \
    -name "$IDENTITY_NAME" \
    -passout pass:bbbtemp

echo "==> Importing into login keychain"
security import "$WORK_DIR/signing.p12" \
    -k "$KEYCHAIN" \
    -P bbbtemp \
    -T /usr/bin/codesign \
    -T /usr/bin/security

echo "==> Marking key as trusted for codesign (won't prompt on future builds)"
security set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -s -k "$(whoami)" \
    -D "$IDENTITY_NAME" \
    -t private \
    "$KEYCHAIN" 2>/dev/null || echo "  (set-key-partition-list may prompt once; OK if so)"

echo
echo "==> Done. Listing code-signing identities:"
security find-identity -v -p codesigning

cat <<NEXT

Next steps:
  1. Re-run:  bash scripts/build-app.sh --install
  2. Grant Full Disk Access one last time to the new bundle
  3. All future rebuilds keep the FDA grant intact
NEXT
