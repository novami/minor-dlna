#!/bin/sh
# Creates the self-signed code signing certificate once. macOS keeps permissions (local network,
# menu bar) for an app signed by the same certificate, unlike ad-hoc signatures that change per build.
# Output: ~/.config/minordlna/codesign.p12; put its base64 into the GitHub secret MINORDLNA_CODESIGN_P12.
set -eu

DIR="$HOME/.config/minordlna"
P12="$DIR/codesign.p12"
[ ! -e "$P12" ] || { echo "$P12 already exists" >&2; exit 1; }
mkdir -p "$DIR"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext
[dn]
CN = MinorDLNA
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
# LibreSSL from macOS writes a PKCS#12 that `security import` reads.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 7300 -config "$TMP/cert.cnf" \
	-keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name MinorDLNA \
	-passout pass:minordlna -out "$P12"
chmod 600 "$P12"
echo "Created $P12 – add it to GitHub:"
echo "  base64 -i $P12 | gh secret set MINORDLNA_CODESIGN_P12"
