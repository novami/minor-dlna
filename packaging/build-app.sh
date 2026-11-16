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

# A stable identifier keeps the macOS local network permission across rebuilds.
codesign --force --sign - --identifier cz.minordlna "$APP"
echo "Built $APP ($VERSION)"
