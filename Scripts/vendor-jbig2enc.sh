#!/bin/bash
# Vendored jbig2enc + Leptonica für PDFdownsize erzeugen (verlustfreies JBIG2).
#
# Ergebnis: statische Archive (nur arm64) in Vendor/jbig2enc:
#
#   Vendor/jbig2enc/include/             jbig2enc.h
#   Vendor/jbig2enc/include/leptonica/   Leptonica-Header (allheaders.h, …)
#   Vendor/jbig2enc/lib/                 libjbig2enc.a + libleptonica.a
#   Vendor/jbig2enc/                     NOTICE-jbig2enc.md (beide Lizenzen)
#
# Aufruf:  ./Scripts/vendor-jbig2enc.sh [--force]
#
# Leptonica zuerst (in ein Install-Präfix), danach jbig2enc mit
# CMAKE_PREFIX_PATH darauf (find_package(Leptonica CONFIG)).
#
# Leptonica mit ALLEN optionalen Codecs OFF: jbig2enc nutzt nur die Pix-Kern-
# API; BMP/PNM sind eingebaut, pixReadTiff existiert als Stub. Ergebnis ohne
# externe Abhängigkeiten (nur libm).
#
# jbig2enc: Master-Commit gepinnt (kein Release-Tag). Refinement wird nie
# benutzt (bekannter Acrobat-Absturz) – nur generisch und verlustfrei.

set -euo pipefail
source "$(dirname "$0")/vendor-common.sh"
parse_force "$@"

LEPT_VERSION="1.87.0"
JB2_COMMIT="23f992c92b10048064602b4d8ea29bb434752634"
DEST="$VENDOR_ROOT/Vendor/jbig2enc"
LEPT_SRC="$WORK/leptonica-$LEPT_VERSION"
JB2_SRC="$WORK/jbig2enc-$JB2_COMMIT"
LEPT_BUILD="$WORK/lept-$VENDOR_ARCH"
LEPT_PREFIX="$WORK/leptonica-install-$VENDOR_ARCH"
JB2_BUILD="$WORK/jb2-$VENDOR_ARCH"

if [ "$FORCE" -eq 0 ] && [ -f "$DEST/lib/libjbig2enc.a" ]; then
    echo "✓ Vendor/jbig2enc existiert bereits – Skip (Neubau mit --force)."
    require_arm64_only "$DEST/lib/libjbig2enc.a" "$DEST/lib/libleptonica.a"
    exit 0
fi

ensure_cmake
fetch_verified "leptonica-$LEPT_VERSION.tar.gz" "$LEPT_SRC"
fetch_verified "jbig2enc-$JB2_COMMIT.tar.gz" "$JB2_SRC"

echo "→ Baue Leptonica $LEPT_VERSION ($VENDOR_ARCH, statisch, ohne Codecs) …"
rm -rf "$LEPT_BUILD" "$LEPT_PREFIX"
"$CM" -S "$LEPT_SRC" -B "$LEPT_BUILD" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES="$VENDOR_ARCH" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$VENDOR_DEPLOYMENT_TARGET" \
    -DCMAKE_INSTALL_PREFIX="$LEPT_PREFIX" \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_PROG=OFF -DSW_BUILD=OFF \
    -DENABLE_ZLIB=OFF -DENABLE_PNG=OFF -DENABLE_GIF=OFF \
    -DENABLE_JPEG=OFF -DENABLE_TIFF=OFF -DENABLE_WEBP=OFF \
    -DENABLE_OPENJPEG=OFF > /dev/null
"$CM" --build "$LEPT_BUILD" --parallel > /dev/null
"$CM" --install "$LEPT_BUILD" > /dev/null

echo "→ Baue jbig2enc @${JB2_COMMIT:0:7} ($VENDOR_ARCH, statisch) …"
rm -rf "$JB2_BUILD"
"$CM" -S "$JB2_SRC" -B "$JB2_BUILD" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES="$VENDOR_ARCH" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$VENDOR_DEPLOYMENT_TARGET" \
    -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_PREFIX_PATH="$LEPT_PREFIX" > /dev/null
"$CM" --build "$JB2_BUILD" --parallel > /dev/null

echo "→ Verifikation (lipo/nm) …"
require_arm64_only "$LEPT_BUILD/src/libleptonica.a" "$JB2_BUILD/liblibjbig2enc.a"
nm -gU "$JB2_BUILD/liblibjbig2enc.a" | c++filt \
    | grep -E "jbig2_init\(|jbig2_add_page\(|jbig2_pages_complete\(|jbig2_produce_page\(|jbig2_encode_generic\(" \
    | sort -u
nm -gU "$LEPT_BUILD/src/libleptonica.a" \
    | grep -E "_pixCreate$|_pixDestroy$|_pixWrite$" | sort -u

rm -rf "$DEST"
mkdir -p "$DEST/include/leptonica" "$DEST/lib"
# CMake nennt das Target "libjbig2enc" und erzeugt daraus liblibjbig2enc.a.
cp "$JB2_BUILD/liblibjbig2enc.a" "$DEST/lib/libjbig2enc.a"
cp "$LEPT_BUILD/src/libleptonica.a" "$DEST/lib/libleptonica.a"
cp "$JB2_SRC/src/jbig2enc.h" "$DEST/include/"
cp "$LEPT_PREFIX/include/leptonica/"*.h "$DEST/include/leptonica/"

{
    echo "# NOTICE – jbig2enc + Leptonica (vendored)"
    echo
    echo "Dieses Verzeichnis enthält statische Build-Artefakt-Kopien (nur arm64) von:"
    echo
    echo "1. **jbig2enc**, Commit \`$JB2_COMMIT\` (kein Release-Tag – Commit gepinnt)"
    echo "   Quelle: https://github.com/agl/jbig2enc"
    echo "   Lizenz: Apache-2.0 (upstream \`COPYING\`, siehe unten)"
    echo
    echo "2. **Leptonica v$LEPT_VERSION**"
    echo "   Quelle: https://github.com/DanBloomberg/leptonica (Tag \`$LEPT_VERSION\`)"
    echo "   Lizenz: BSD-artig (upstream \`leptonica-license.txt\`, siehe unten)"
    echo
    echo "Beide Tarballs werden per SHA-256 geprüft (Scripts/vendor-common.sh)."
    echo
    echo "Verwendung: verlustfreies JBIG2-Encoding für Bilevel-PDF-Bilder."
    echo "Keine Änderungen am Quellcode."
    echo "Regeln: NUR verlustfrei, KEIN Refinement (bekannter Acrobat-Absturz)."
    echo
    echo "Build-Konfiguration: Release, BUILD_SHARED_LIBS=OFF. Leptonica mit ALLEN"
    echo "optionalen Codecs OFF (zlib/png/gif/jpeg/tiff/webp/openjpeg) – BMP/PNM"
    echo "sind eingebaut; jbig2enc benötigt nur die Pix-Kern-API. Deployment-Target"
    echo "macOS $VENDOR_DEPLOYMENT_TARGET. Nur System-Abhängigkeiten (libm)."
    echo
    echo "---"
    echo
    echo "## Lizenz jbig2enc (upstream \`COPYING\`)"
    echo
    echo '```'
    cat "$JB2_SRC/COPYING"
    echo '```'
    echo
    echo "## Lizenz Leptonica (upstream \`leptonica-license.txt\`)"
    echo
    echo '```'
    cat "$LEPT_SRC/leptonica-license.txt"
    echo '```'
} > "$DEST/NOTICE-jbig2enc.md"

echo
echo "✓ Vendored: $DEST"
require_arm64_only "$DEST/lib/libjbig2enc.a" "$DEST/lib/libleptonica.a"
