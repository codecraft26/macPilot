#!/usr/bin/env bash
# Creates a self-signed code-signing certificate "MacPilot Local Signing" in your login Keychain, so
# scripts/build-app.sh signs every build with the same identity. macOS then keeps MacPilot's privacy
# grants (Device Control / Accessibility, Screen Recording) and Keychain access across rebuilds.
#
# Run it yourself, once: scripts/create-local-signing-cert.sh
# It asks for your login password (to trust the certificate for code signing). Nothing leaves this Mac.
# Remove it later in Keychain Access → login → My Certificates → "MacPilot Local Signing".
set -euo pipefail

NAME="${LOCAL_SIGN_IDENTITY:-MacPilot Local Signing}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
  echo "\"$NAME\" already exists and is valid for code signing. Nothing to do."
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/cert.cnf" <<CNF
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = $NAME
[ ext ]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF

# 10-year self-signed certificate with a new 2048-bit key.
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/cert.cnf" \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" >/dev/null 2>&1
PASS="$(openssl rand -hex 16)"
openssl pkcs12 -export -legacy -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
  -out "$WORK/identity.p12" -passout "pass:$PASS" 2>/dev/null \
  || openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" -out "$WORK/identity.p12" -passout "pass:$PASS"

# Import the key and certificate; only codesign may use the key without asking.
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign
# Trust it for code signing (macOS asks for your password).
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
  echo "Created \"$NAME\". Rebuild with scripts/build-app.sh (or scripts/package.sh); it is used automatically."
else
  echo "The certificate was imported but isn't valid for code signing yet. Open Keychain Access, find \"$NAME\","
  echo "and set Trust → Code Signing to Always Trust."
  exit 1
fi
