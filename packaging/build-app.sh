#!/bin/sh
# Builds dist/MinorDLNA.app (universal binary, ad-hoc signed).
# Regenerate packaging/AppIcon.icns from the icon renderer:
#   ICON_OUT=icon_512x512@2x.png ICON_SIZE=1024 go test ./internal/icon -run TestExportIcon
set -eu

cd "$(dirname "$0")/.."
VERSION="${VERSION:-$(git describe --tags --always --dirty 2>/dev/null || echo dev)}"
PLIST_VERSION="$(echo "$VERSION" | sed -E 's/^v//; s/[^0-9.].*$//')"
[ -n "$PLIST_VERSION" ] || PLIST_VERSION="0.0.0"
APP=dist/MinorDLNA.app
LDFLAGS="-s -w -X github.com/novami/minor-dlna/internal/version.Version=$VERSION"

mkdir -p dist
if [ -d "$APP" ]; then
	rm -r "$APP"
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# cgo is needed for the menu bar icon (Cocoa); clang cross-compiles both architectures.
export CGO_ENABLED=1 MACOSX_DEPLOYMENT_TARGET=12.0
GOOS=darwin GOARCH=arm64 CC="clang -arch arm64" go build -ldflags "$LDFLAGS" -o dist/minordlna-arm64 ./cmd/minordlna
GOOS=darwin GOARCH=amd64 CC="clang -arch x86_64" go build -ldflags "$LDFLAGS" -o dist/minordlna-amd64 ./cmd/minordlna
lipo -create -output "$APP/Contents/MacOS/minordlna" dist/minordlna-arm64 dist/minordlna-amd64
rm dist/minordlna-arm64 dist/minordlna-amd64

sed "s/__VERSION__/$PLIST_VERSION/g" packaging/Info.plist > "$APP/Contents/Info.plist"
cp packaging/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Signed by our own certificate, macOS keeps the local network and menu bar permissions across
# builds and updates. The certificate comes from MINORDLNA_CODESIGN_P12 (base64, CI) or
# ~/.config/minordlna/codesign.p12 (packaging/codesign-keygen.sh); without it, ad-hoc signing.
P12="$HOME/.config/minordlna/codesign.p12"
KC=""
if [ -n "${MINORDLNA_CODESIGN_P12:-}" ]; then
	P12="$(mktemp)"
	echo "$MINORDLNA_CODESIGN_P12" | base64 -D > "$P12"
fi
if [ -s "$P12" ]; then
	KC="$(mktemp -d)/minordlna-sign.keychain-db"
	# Older macOS finds identities only in keychains on the search list.
	OLD_KCS="$(security list-keychains -d user | tr -d '"' | xargs)"
	trap 'security list-keychains -d user -s $OLD_KCS; security delete-keychain "$KC" 2>/dev/null || true' EXIT
	security create-keychain -p minordlna "$KC"
	security unlock-keychain -p minordlna "$KC"
	security import "$P12" -f pkcs12 -k "$KC" -P minordlna -T /usr/bin/codesign >/dev/null
	security set-key-partition-list -S apple-tool:,apple: -k minordlna "$KC" >/dev/null
	security list-keychains -d user -s "$KC" $OLD_KCS
	# By hash, codesign takes the self-signed (untrusted) identity, which a name lookup may skip.
	HASH="$(/usr/bin/openssl pkcs12 -in "$P12" -nokeys -passin pass:minordlna 2>/dev/null |/usr/bin/openssl x509 -noout -fingerprint -sha1 | sed 's/.*=//; s/://g')"
	codesign --force --sign "$HASH" --keychain "$KC" --identifier cz.minordlna "$APP" ||
		{ security find-identity "$KC" >&2; exit 1; }
else
	echo "warning: no signing certificate, signing ad-hoc (macOS asks for permissions after every build)" >&2
	codesign --force --sign - --identifier cz.minordlna "$APP"
fi
# The bundle is recreated at the same path, so Finder keeps its cached (generic) icon until told otherwise.
touch "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" || true
echo "Built $APP ($VERSION)"
