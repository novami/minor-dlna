#!/bin/bash
# Builds the LGPL ffmpeg and ffprobe bundled in Contents/Helpers (arm64, macOS 26). Output: build/ffmpeg/out/.
# The source tarball is pinned by version and SHA-256; nothing GPL or nonfree is enabled.
# Run by the "Build ffmpeg" phase of the app target; does nothing when the build is current.
set -euo pipefail

VERSION=9.0.2
SHA256=8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e
URL="https://ffmpeg.org/releases/ffmpeg-$VERSION.tar.xz"
TARGET=26.0

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${FFMPEG_BUILD_DIR:-$ROOT/build/ffmpeg}"
OUT="$WORK/out"
STAMP="$OUT/.stamp"
WANT="$VERSION $SHA256 $TARGET $(shasum -a 256 "$0" | cut -d' ' -f1)"

if [ -x "$OUT/ffmpeg" ] && [ -x "$OUT/ffprobe" ] && [ "$(cat "$STAMP" 2>/dev/null)" = "$WANT" ]; then
	exit 0
fi

mkdir -p "$WORK"
TARBALL="$WORK/ffmpeg-$VERSION.tar.xz"
if [ ! -f "$TARBALL" ] || [ "$(shasum -a 256 "$TARBALL" | cut -d' ' -f1)" != "$SHA256" ]; then
	echo "Downloading ffmpeg $VERSION"
	curl -fsSL -o "$TARBALL" "$URL"
fi
[ "$(shasum -a 256 "$TARBALL" | cut -d' ' -f1)" = "$SHA256" ] || { echo "error: ffmpeg tarball SHA-256 mismatch" >&2; exit 1; }

SRC="$WORK/src"
rm -rf "$SRC" "$OUT"
mkdir -p "$SRC" "$OUT"
tar -xJf "$TARBALL" -C "$SRC" --strip-components=1

cd "$SRC"
export MACOSX_DEPLOYMENT_TARGET="$TARGET"
./configure \
	--arch=arm64 --cc=clang \
	--extra-cflags="-arch arm64 -mmacosx-version-min=$TARGET" \
	--extra-ldflags="-arch arm64 -mmacosx-version-min=$TARGET" --extra-libs="-liconv" \
	--disable-gpl --disable-nonfree --disable-autodetect \
	--disable-shared --enable-static \
	--disable-doc --disable-debug --disable-ffplay --disable-network \
	--enable-ffmpeg --enable-ffprobe \
	--enable-videotoolbox --enable-audiotoolbox \
	--enable-zlib --enable-bzlib --enable-iconv
make -j"$(sysctl -n hw.ncpu)"
cp ffmpeg ffprobe "$OUT/"
strip -x "$OUT/ffmpeg" "$OUT/ffprobe"

# Checks: LGPL only, arm64 only, no libraries outside the system.
if "$OUT/ffmpeg" -buildconf | grep -q -e '--enable-gpl' -e '--enable-nonfree' -e 'libx26'; then
	echo "error: the build is not LGPL" >&2
	exit 1
fi
[ "$(lipo -archs "$OUT/ffmpeg")" = "arm64" ] || { echo "error: ffmpeg is not arm64" >&2; exit 1; }
if otool -L "$OUT/ffmpeg" | tail -n +2 | grep -v -e '^[[:space:]]*/usr/lib/' -e '^[[:space:]]*/System/Library/'; then
	echo "error: ffmpeg links a library outside the system" >&2
	exit 1
fi

cp COPYING.LGPLv2.1 "$OUT/FFMPEG-LICENSE.txt"
echo "$WANT" > "$STAMP"
echo "ffmpeg $VERSION ready in $OUT"
