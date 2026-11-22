#!/bin/bash
# Vendored libdeflate für PDFdownsize erzeugen (schnelles, kompaktes RFC-1950-zlib).
#
# Ergebnis: statische libdeflate.a (nur arm64) in Vendor/libdeflate.
#
#   Vendor/libdeflate/include/  libdeflate.h
#   Vendor/libdeflate/lib/      libdeflate.a
#   Vendor/libdeflate/          NOTICE-libdeflate.md
#
# Aufruf:  ./Scripts/vendor-libdeflate.sh [--force]

set -euo pipefail
source "$(dirname "$0")/vendor-common.sh"
parse_force "$@"

VERSION="1.25"
DEST="$VENDOR_ROOT/Vendor/libdeflate"
SRC="$WORK/libdeflate-$VERSION"
BUILD="$WORK/libdeflate-$VENDOR_ARCH"

if [ "$FORCE" -eq 0 ] && [ -f "$DEST/lib/libdeflate.a" ]; then
    echo "✓ Vendor/libdeflate existiert bereits – Skip (Neubau mit --force)."
    require_arm64_only "$DEST/lib/libdeflate.a"
    exit 0
fi

ensure_cmake
fetch_verified "libdeflate-$VERSION.tar.gz" "$SRC"

echo "→ Baue libdeflate $VERSION ($VENDOR_ARCH, statisch, nur Bibliothek) …"
rm -rf "$BUILD"
"$CM" -S "$SRC" -B "$BUILD" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES="$VENDOR_ARCH" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$VENDOR_DEPLOYMENT_TARGET" \
    -DLIBDEFLATE_BUILD_STATIC_LIB=ON \
    -DLIBDEFLATE_BUILD_SHARED_LIB=OFF \
    -DLIBDEFLATE_BUILD_GZIP=OFF \
    -DLIBDEFLATE_BUILD_TESTS=OFF > /dev/null
"$CM" --build "$BUILD" --parallel > /dev/null

echo "→ Verifikation (lipo/nm) …"
require_arm64_only "$BUILD/libdeflate.a"
nm -gU "$BUILD/libdeflate.a" \
    | grep -E "_libdeflate_alloc_compressor|_libdeflate_zlib_compress|_libdeflate_free_compressor" | sort -u

rm -rf "$DEST"
mkdir -p "$DEST/include" "$DEST/lib"
cp "$BUILD/libdeflate.a" "$DEST/lib/libdeflate.a"
cp "$SRC/libdeflate.h" "$DEST/include/"

{
    echo "# NOTICE – libdeflate (vendored)"
    echo
    echo "Dieses Verzeichnis enthält eine statische Build-Artefakt-Kopie (nur arm64)"
    echo "von **libdeflate v$VERSION**."
    echo
    echo "- Quelle: https://github.com/ebiggers/libdeflate (Release \`v$VERSION\`,"
    echo "  Tarball https://github.com/ebiggers/libdeflate/archive/refs/tags/v$VERSION.tar.gz,"
    echo "  per SHA-256 geprüft)"
    echo "- Lizenz: MIT, upstream \`COPYING\`."
    echo "- Verwendung: Schnelle, kompakte RFC-1950-zlib/DEFLATE-Kodierung für"
    echo "  Flate-Bildströme (verlustfreier Resize, Paletten, Grafiken)."
    echo "  Keine Änderungen am Quellcode."
    echo "- Build-Konfiguration: Release, LIBDEFLATE_BUILD_STATIC_LIB=ON,"
    echo "  LIBDEFLATE_BUILD_SHARED_LIB=OFF, LIBDEFLATE_BUILD_GZIP=OFF,"
    echo "  LIBDEFLATE_BUILD_TESTS=OFF. Deployment-Target macOS $VENDOR_DEPLOYMENT_TARGET."
    echo
    echo "Original-Lizenztext:"
    echo
    cat "$SRC/COPYING"
} > "$DEST/NOTICE-libdeflate.md"

echo
echo "✓ Vendored: $DEST"
require_arm64_only "$DEST/lib/libdeflate.a"
