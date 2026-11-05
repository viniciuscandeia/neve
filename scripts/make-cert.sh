#!/usr/bin/env bash
# Creates a self-signed code-signing identity "Neve Local Signing" in the login keychain.
# Signing with a stable identity keeps macOS privacy permissions (Accessibility) across rebuilds.
set -euo pipefail
NAME="Neve Local Signing"
if security find-identity -p codesigning | grep -q "$NAME"; then
  echo "Identity '$NAME' already exists."; exit 0
fi
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/cfg" <<CFG
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CFG
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$tmp/cfg" \
  -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
  -name "$NAME" -passout pass:neve -out "$tmp/id.p12"
security import "$tmp/id.p12" -k ~/Library/Keychains/login.keychain-db -P neve -T /usr/bin/codesign
echo "Trusting the certificate for code signing (macOS will ask for your login password)..."
security add-trusted-cert -r trustRoot -p codeSign -k ~/Library/Keychains/login.keychain-db "$tmp/cert.pem"
echo "Created '$NAME'."
