#!/bin/bash
# Vendored OpenJPEG für PDFdownsize erzeugen (nur JPX-Dekodierung).
#
# JPX-Streams in Eingabe-PDFs werden dekodiert, um übergroße JPX-Bilder
# herunterzurechnen und als JPEG bzw. Flate neu zu kodieren. Es wird nie JPX
# geschrieben (PDFKit-Risiko).
#
# Ergebnis: statische libopenjpeg.a (nur arm64) in Vendor/openjpeg:
#
#   Vendor/openjpeg/include/openjpeg-2.5/  openjpeg.h + opj_config.h
#   Vendor/openjpeg/lib/                   libopenjpeg.a
#   Vendor/openjpeg/                       NOTICE-openjpeg.md
#
# Aufruf:  ./Scripts/vendor-openjpeg.sh [--force]
#
# Alle optionalen Drittanbieter-Suchen sind aus (zlib, tiff, lcms, lcms2).
# Diese Bibliotheken braucht OpenJPEG nur für die Bild-IO und das
# Farbmanagement der Kommandozeilenwerkzeuge; der Kern (libopenjp2) braucht
# nur libm. Die Farbinformation kommt PDF-seitig aus /ColorSpace. Die
# Werkzeuge werden nicht gebaut (BUILD_CODEC=OFF).

set -euo pipefail
source "$(dirname "$0")/vendor-common.sh"
parse_force "$@"

VERSION="2.5.4"
DEST="$VENDOR_ROOT/Vendor/openjpeg"
SRC="$WORK/openjpeg-$VERSION"
BUILD="$WORK/openjpeg-$VENDOR_ARCH"
PREFIX="$WORK/openjpeg-install-$VENDOR_ARCH"

if [ "$FORCE" -eq 0 ] && [ -f "$DEST/lib/libopenjpeg.a" ]; then
    echo "✓ Vendor/openjpeg existiert bereits – Skip (Neubau mit --force)."
    require_arm64_only "$DEST/lib/libopenjpeg.a"
    exit 0
fi

ensure_cmake
fetch_verified "openjpeg-$VERSION.tar.gz" "$SRC"

echo "→ Baue OpenJPEG $VERSION ($VENDOR_ARCH, statisch, ohne Drittanbieter) …"
rm -rf "$BUILD" "$PREFIX"
"$CM" -S "$SRC" -B "$BUILD" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES="$VENDOR_ARCH" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$VENDOR_DEPLOYMENT_TARGET" \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_STATIC_LIBS=ON \
    -DBUILD_CODEC=OFF \
    -DBUILD_TESTING=OFF \
    -DBUILD_DOC=OFF \
    -DCMAKE_DISABLE_FIND_PACKAGE_ZLIB=TRUE \
    -DCMAKE_DISABLE_FIND_PACKAGE_TIFF=TRUE \
    -DCMAKE_DISABLE_FIND_PACKAGE_LCMS=TRUE \
    -DCMAKE_DISABLE_FIND_PACKAGE_LCMS2=TRUE > /dev/null
"$CM" --build "$BUILD" --parallel > /dev/null
"$CM" --install "$BUILD" > /dev/null

LIB="$BUILD/bin/libopenjp2.a"
echo "→ Verifikation (lipo/nm) …"
require_arm64_only "$LIB"
nm -gU "$LIB" \
    | grep -E "_opj_create_decompress$|_opj_decode$|_opj_read_header$|_opj_set_decode_area$" | sort -u
# Hermetie: keine offenen Verweise auf zlib/png/tiff/lcms.
UNDEF=$(nm -u "$LIB" | grep -iE "lcms|png_|tiff_|inflate|deflate" || true)
if [ -n "$UNDEF" ]; then
    echo "FEHLER: libopenjp2.a verweist auf Drittanbieter-Symbole:" >&2
    echo "$UNDEF" >&2
    exit 1
fi

rm -rf "$DEST"
mkdir -p "$DEST/lib"
INC_SUBDIR="$(cd "$PREFIX/include" && ls -d openjpeg-*)"
mkdir -p "$DEST/include/$INC_SUBDIR"
cp "$PREFIX/include/$INC_SUBDIR/"*.h "$DEST/include/$INC_SUBDIR/"
# Upstream heißt das Archiv libopenjp2.a (Target "openjp2").
cp "$LIB" "$DEST/lib/libopenjpeg.a"

{
    echo "# NOTICE – OpenJPEG (vendored)"
    echo
    echo "Dieses Verzeichnis enthält eine statische Build-Artefakt-Kopie (nur arm64)"
    echo "von **OpenJPEG v$VERSION**."
    echo
    echo "- Quelle: https://github.com/uclouvain/openjpeg (Tag \`v$VERSION\`,"
    echo "  Tarball https://github.com/uclouvain/openjpeg/archive/refs/tags/v$VERSION.tar.gz,"
    echo "  per SHA-256 geprüft)"
    echo "- Lizenz: BSD-2-Klausel (upstream \`LICENSE\`, Volltext unten)."
    echo "- Verwendung: Dekodierung von \`/JPXDecode\`-Streams (JPEG 2000 rohe"
    echo "  Codestreams + JP2-Container) für die Neukompression übergroßer"
    echo "  JPX-Bilder. Ausdrücklich NUR Dekodierpfad: kein JPX-Output"
    echo "  (PDFKit-Risiko). Keine Änderungen am Quellcode."
    echo "- Build-Konfiguration: Release, BUILD_SHARED_LIBS=OFF,"
    echo "  BUILD_STATIC_LIBS=ON, BUILD_CODEC=OFF, BUILD_TESTING=OFF,"
    echo "  BUILD_DOC=OFF. Alle optionalen Drittanbieter-Bibliotheken"
    echo "  deaktiviert (zlib/png/tiff/lcms/lcms2) – der Kern braucht nur libm."
    echo "  Deployment-Target macOS $VENDOR_DEPLOYMENT_TARGET."
    echo
    echo "Original-Lizenztext:"
    echo
    echo '```'
    cat "$SRC/LICENSE"
    echo '```'
} > "$DEST/NOTICE-openjpeg.md"

echo
echo "✓ Vendored: $DEST"
require_arm64_only "$DEST/lib/libopenjpeg.a"
