#!/bin/bash
# Creates a self-signed code-signing certificate in your login keychain, used only on this Mac.
#
# Why: ad-hoc signed builds get a new identity every time, so macOS asks again for
# Keychain access (the saved API keys) after each rebuild. Signing every build with the same
# certificate keeps the identity stable, so "Always Allow" sticks.
#
# Safe to run more than once; does nothing if the certificate already exists.
set -euo pipefail

NAME="LoadLens Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "已存在签名证书：$NAME"
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cert.cnf" <<EOF
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
EOF

openssl req -new -newkey rsa:2048 -nodes -x509 -days 3650 \
    -config "$WORK/cert.cnf" -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null

PASS="$(openssl rand -hex 16)"
openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -name "$NAME" -out "$WORK/identity.p12" -passout "pass:$PASS" 2>/dev/null

# -T lets codesign use the private key without asking each time.
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null

echo "已创建签名证书：$NAME（只保存在本机登录钥匙串）"
