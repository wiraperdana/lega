#!/bin/bash
# Membuat sertifikat penandatangan self-signed "Lega Developer" di login keychain.
# Tujuannya: identitas Lega tetap sama antar build, jadi izin macOS (TCC) cukup diberikan sekali.
# Ad-hoc signing (`codesign --sign -`) memberi identitas baru tiap build, sehingga izin ditanyakan ulang.
set -euo pipefail
NAME="Lega Developer"
if security find-identity -v -p codesigning | grep -q "$NAME"; then echo "Sudah ada: $NAME"; exit 0; fi
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cfg" <<CFG
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$NAME
[ext]
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
basicConstraints=critical,CA:false
CFG
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout "$TMP/k.pem" -out "$TMP/c.pem" -config "$TMP/cfg" 2>/dev/null
openssl pkcs12 -export -legacy -inkey "$TMP/k.pem" -in "$TMP/c.pem" -out "$TMP/c.p12" -passout pass:lega 2>/dev/null \
  || openssl pkcs12 -export -inkey "$TMP/k.pem" -in "$TMP/c.pem" -out "$TMP/c.p12" -passout pass:lega
security import "$TMP/c.p12" -k ~/Library/Keychains/login.keychain-db -P lega -T /usr/bin/codesign
echo "Dibuat: $NAME"
