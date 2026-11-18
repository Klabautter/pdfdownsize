#!/bin/bash
# Vendored libtiff für PDFdownsize erzeugen (CCITT-G4-Kodierung).
#
# Ergebnis: statische libtiff.a (nur arm64) in Vendor/libtiff.
#
#   Vendor/libtiff/include/  tiff.h, tiffio.h, tiffconf.h, tiffvers.h
#   Vendor/libtiff/lib/      libtiff.a
#   Vendor/libtiff/          NOTICE-libtiff.md
#
# Aufruf:  ./Scripts/vendor-libtiff.sh [--force]

set -euo pipefail
source "$(dirname "$0")/vendor-common.sh"
parse_force "$@"

VERSION="4.7.2"
DEST="$VENDOR_ROOT/Vendor/libtiff"
SRC="$WORK/tiff-$VERSION"
BUILD="$WORK/tiff-$VENDOR_ARCH"

if [ "$FORCE" -eq 0 ] && [ -f "$DEST/lib/libtiff.a" ]; then
    echo "✓ Vendor/libtiff existiert bereits – Skip (Neubau mit --force)."
    require_arm64_only "$DEST/lib/libtiff.a"
    exit 0
fi

ensure_cmake
fetch_verified "tiff-$VERSION.tar.gz" "$SRC"

echo "→ Baue libtiff $VERSION ($VENDOR_ARCH, statisch, nur CCITT/LZW/PackBits) …"
rm -rf "$BUILD"
"$CM" -S "$SRC" -B "$BUILD" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES="$VENDOR_ARCH" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$VENDOR_DEPLOYMENT_TARGET" \
    -DBUILD_SHARED_LIBS=OFF \
    -Dtiff-static=ON \
    -Dtiff-tools=OFF -Dtiff-tests=OFF -Dtiff-contrib=OFF \
    -Dtiff-docs=OFF -Dtiff-install=OFF \
    -Dtiff-cxx=OFF \
    -Dzlib=OFF -Dzstd=OFF -Dlzma=OFF -Djpeg=OFF -Dwebp=OFF \
    -Djbig=OFF -Dlerc=OFF -Dlibdeflate=OFF -Dpixarlog=OFF > /dev/null
"$CM" --build "$BUILD" --parallel > /dev/null

echo "→ Verifikation (lipo/nm) …"
require_arm64_only "$BUILD/libtiff/libtiff.a"
nm -gU "$BUILD/libtiff/libtiff.a" \
    | grep -E "_TIFFWriteScanline|_TIFFReadScanline|_TIFFSetField" | sort -u

rm -rf "$DEST"
mkdir -p "$DEST/include" "$DEST/lib"
cp "$BUILD/libtiff/libtiff.a" "$DEST/lib/libtiff.a"
cp "$SRC/libtiff/tiff.h" "$SRC/libtiff/tiffio.h" "$DEST/include/"
cp "$BUILD/libtiff/tiffconf.h" "$BUILD/libtiff/tiffvers.h" "$DEST/include/"

{
    echo "# NOTICE – libtiff (vendored)"
    echo
    echo "Dieses Verzeichnis enthält eine statische Build-Artefakt-Kopie (nur arm64)"
    echo "von **libtiff v$VERSION**."
    echo
    echo "- Quelle: https://gitlab.com/libtiff/libtiff (Release \`v$VERSION\`,"
    echo "  Tarball https://download.osgeo.org/libtiff/tiff-$VERSION.tar.gz,"
    echo "  per SHA-256 geprüft)"
    echo "- Lizenz: BSD-artig (Sam Leffler / Silicon Graphics), upstream \`LICENSE.md\`."
    echo "- Verwendung: CCITT G3/G4-Encoding (Fax-Codec) für Bilevel-PDF-Bilder."
    echo "  Keine Änderungen am Quellcode."
    echo "- Build-Konfiguration: Release, BUILD_SHARED_LIBS=OFF, tiff-cxx=OFF,"
    echo "  alle optionalen Codecs OFF (zlib/zstd/lzma/jpeg/webp/jbig/lerc/"
    echo "  libdeflate/pixarlog). CCITT-Fax-Codec default-ON. Deployment-Target"
    echo "  macOS $VENDOR_DEPLOYMENT_TARGET. Tools/Tests/Docs nicht enthalten."
    echo
    echo "Original-Lizenztext:"
    echo
    cat "$SRC/LICENSE.md"
} > "$DEST/NOTICE-libtiff.md"

echo
echo "✓ Vendored: $DEST"
require_arm64_only "$DEST/lib/libtiff.a"
