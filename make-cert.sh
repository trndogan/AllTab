#!/bin/zsh
# "WinTab Yerel Imza" adlı, kod imzalama için kendinden imzalı yerel bir sertifika üretir ve
# giriş anahtar zincirine ekler. Böylece build.sh her derlemede aynı imzayı kullanır ve
# macOS Erişilebilirlik / Ekran Kaydı izinleri yeniden derlemelerde korunur.
# Apple geliştirici hesabı gerekmez. Sertifika yalnızca bu Mac'te geçerlidir.
set -e
NAME="WinTab Yerel Imza"
KC="$HOME/Library/Keychains/login.keychain-db"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
  echo "Zaten var: $NAME"; exit 0
fi

cat > "$TMP/ext.cnf" <<EOF
[req]
distinguished_name=dn
x509_extensions=v3
prompt=no
[dn]
CN=$NAME
[v3]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
subjectKeyIdentifier=hash
EOF
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -days 3650 -config "$TMP/ext.cnf" -sha256 2>/dev/null
P="$(head -c 24 /dev/urandom | base64)"
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/cert.p12" -name "$NAME" -passout "pass:$P"
security import "$TMP/cert.p12" -k "$KC" -P "$P" -T /usr/bin/codesign -T /usr/bin/security
security add-trusted-cert -r trustRoot -p codeSign -k "$KC" "$TMP/cert.pem"
echo "Eklendi: $NAME"
security find-identity -v -p codesigning | grep "$NAME"
