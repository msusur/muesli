#!/usr/bin/env bash
# Creates a self-signed code-signing certificate, "Muesli Local Signing", in
# your login keychain. scripts/bundle-app.sh uses it automatically.
#
# Why: an ad-hoc signed app is identified by a hash of its exact build, so macOS
# forgets its microphone and system-audio permissions after every rebuild. An
# app signed with a certificate is identified by its bundle id and that
# certificate, which stay the same, so permissions are asked for once.
#
# The certificate is only good for signing on this Mac; it isn't trusted by
# anyone else and isn't needed for anything else. Remove it with Keychain Access.
set -euo pipefail

NAME="Muesli Local Signing"
if security find-certificate -c "$NAME" >/dev/null 2>&1; then
  echo "“$NAME” already exists."
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.conf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.conf" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
PASS="$(openssl rand -hex 16)"
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
  -out "$TMP/identity.p12" -passout "pass:$PASS"

# -T lets codesign use the key without a keychain prompt on every build.
security import "$TMP/identity.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
  -P "$PASS" -T /usr/bin/codesign
echo "created “$NAME”. Rebuild with scripts/bundle-app.sh --install."
