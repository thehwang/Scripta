#!/bin/bash
set -e

CERT_NAME="Scripta Dev"
KEYCHAIN=~/Library/Keychains/login.keychain-db

if security find-identity -v -p codesigning | grep -q "$CERT_NAME"; then
    echo "Certificate '$CERT_NAME' already exists and is valid for codesigning."
    exit 0
fi

# Remove any stale cert with the same CN
security delete-certificate -c "$CERT_NAME" "$KEYCHAIN" 2>/dev/null || true

echo "Creating self-signed code signing certificate '$CERT_NAME' ..."

TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

cat > "$TMPDIR/cert.cfg" << 'EOF'
[ req ]
default_bits       = 2048
distinguished_name = dn
prompt             = no
x509_extensions    = codesign

[ dn ]
CN = Scripta Dev
O  = Scripta Developer

[ codesign ]
keyUsage           = critical, digitalSignature
extendedKeyUsage   = critical, codeSigning
basicConstraints   = critical, CA:false
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -config "$TMPDIR/cert.cfg" \
    -keyout "$TMPDIR/key.pem" -out "$TMPDIR/cert.pem" 2>/dev/null

# Use -legacy flag for OpenSSL 3.x compatibility with macOS Keychain
openssl pkcs12 -export -inkey "$TMPDIR/key.pem" -in "$TMPDIR/cert.pem" \
    -out "$TMPDIR/cert.p12" -passout pass:temp -legacy 2>/dev/null

# Import private key + cert
security import "$TMPDIR/cert.p12" -k "$KEYCHAIN" \
    -P temp -T /usr/bin/codesign 2>/dev/null

# Trust the cert for code signing (may prompt for macOS password)
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$TMPDIR/cert.pem" 2>/dev/null || true

# Allow codesign to access without prompt
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "$KEYCHAIN" 2>/dev/null || true

echo ""
if security find-identity -v -p codesigning | grep -q "$CERT_NAME"; then
    echo "Certificate '$CERT_NAME' created, imported, and trusted for codesigning."
else
    echo "Certificate imported but needs manual trust:"
    echo "  1. Open Keychain Access"
    echo "  2. Find '$CERT_NAME' in 'login' keychain"
    echo "  3. Double-click → Trust → Code Signing → Always Trust"
fi
