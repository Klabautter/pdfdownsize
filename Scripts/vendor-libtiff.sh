#!/bin/bash
# Vendored libtiff für PDFTools erzeugen (Roadmap Phase 2: CCITT G4-Encoding).
#
# Ergebnis: EINE universelle (arm64 + x86_64) STATISCHE libtiff.a in
# Vendor/libtiff – analog zu vendor-mozjpeg.sh (nur System-Abhängigkeiten,
# keine Dylibs, kein Homebrew auf dem Zielrechner).
#
#   Vendor/libtiff/include/  tiffio.h, tiff.h, tiffconf.h, tiffvers.h
#   Vendor/libtiff/lib/      libtiff.a (fett: arm64 + x86_64)
#   Vendor/libtiff/          NOTICE-libtiff.md
#
# Die Tools (tiffcp, tiffinfo, …) bleiben unter /tmp/opencode – die App braucht
# nur die LIB. Keine Tool-Binaries im App-Bundle.
#
# Aufruf:            ./Scripts/vendor-libtiff.sh [--force]
# Standard-Version:  4.7.2 (aktuelles stabiles Release, download.osgeo.org
#                    Aug 2026 ermittelt)
#
# Build-Konfiguration (minimal, Fax-Codec ist im Default-CCITT-Pfad enthalten
# und hat KEINEN Abschalt-Schalter – CCITT G3/G4 läuft ohne externe Libs):
#   - BUILD_SHARED_LIBS=0 → nur libtiff.a (statisch)
#   - alle optionalen Codecs explizit OFF: zlib/deflate, zstd, lzma, jpeg,
#     webp, jbig (JBIG-KIT, NICHT CCITT!), lerc, libdeflate, pixarlog
#   - tiff-cxx=OFF → keine C++-Stream-API (tif_stream.cxx), reine C-API
#   - Tools/Tests/Contrib/Docs aus → schneller hermetischer Build
#   - Ergebnis-Nachweis: Compression-Tag COMPRESSION_CCITTFAX4 schreiben und
#     zurücklesen (Funktionstest separat, siehe Rapport Phase 2a)

set -euo pipefail

VERSION="4.7.2"
WORK="/tmp/opencode/pdftools-vendor"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Vendor/libtiff"
CM="$WORK/cmake-app/CMake.app/Contents/bin/cmake"
ARCHS="arm64;x86_64"
SRC="$WORK/tiff-$VERSION"

# --- Argumente: --force erzwingt Neubau ---------------------------------------
FORCE=0
for ARG in "$@"; do
    case "$ARG" in
        --force) FORCE=1 ;;
        *) echo "Unbekanntes Argument: $ARG (erlaubt: --force)" >&2; exit 1 ;;
    esac
done

if [ "$FORCE" -eq 0 ] && [ -f "$DEST/lib/libtiff.a" ]; then
    echo "✓ Vendor/libtiff existiert bereits – Skip (Neubau mit --force)."
    lipo -info "$DEST/lib/libtiff.a"
    exit 0
fi

mkdir -p "$WORK" "$DEST"

# --- Werkzeuge & Quellen besorgen (Pfad-Wiederverwendung wie vendor-qpdf.sh) --
if [ ! -x "$CM" ]; then
    echo "→ Lade CMake (universal) …"
    curl -sL --max-time 300 -o "$WORK/cmake.tar.gz" \
        "https://github.com/Kitware/CMake/releases/download/v3.30.5/cmake-3.30.5-macos-universal.tar.gz"
    tar xzf "$WORK/cmake.tar.gz" -C "$WORK"
    mv "$WORK/cmake-3.30.5-macos-universal" "$WORK/cmake-app"
fi

if [ ! -d "$SRC" ]; then
    echo "→ Lade libtiff $VERSION …"
    curl -sL --max-time 300 -o "$WORK/tiff-src.tar.gz" \
        "https://download.osgeo.org/libtiff/tiff-$VERSION.tar.gz"
    tar xzf "$WORK/tiff-src.tar.gz" -C "$WORK"
fi

# --- libtiff: pro Architektur statisch bauen, dann .a mergen -------------------
# Muster aus vendor-mozjpeg.sh: beide Architekturen einzeln mit
# CMAKE_OSX_ARCHITECTURES, danach libtool -static zum Fat-Archiv.
echo "→ Baue libtiff $VERSION (arm64 + x86_64, statisch, nur CCITT/LZW/PackBits) …"
for ARCH in arm64 x86_64; do
    if [ "$FORCE" -eq 1 ] || [ ! -f "$WORK/tiff-$ARCH/libtiff/libtiff.a" ]; then
        "$CM" -S "$SRC" -B "$WORK/tiff-$ARCH" \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_OSX_ARCHITECTURES=$ARCH \
            -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0 \
            -DBUILD_SHARED_LIBS=OFF \
            -Dtiff-static=ON \
            -Dtiff-tools=OFF -Dtiff-tests=OFF -Dtiff-contrib=OFF \
            -Dtiff-docs=OFF -Dtiff-install=OFF \
            -Dtiff-cxx=OFF \
            -Dzlib=OFF -Dzstd=OFF -Dlzma=OFF -Djpeg=OFF -Dwebp=OFF \
            -Djbig=OFF -Dlerc=OFF -Dlibdeflate=OFF -Dpixarlog=OFF > /dev/null
        "$CM" --build "$WORK/tiff-$ARCH" --parallel > /dev/null
    fi
done

mkdir -p "$WORK/tiff-universal/lib" "$WORK/tiff-universal/bin"
libtool -static -o "$WORK/tiff-universal/lib/libtiff.a" \
    "$WORK/tiff-arm64/libtiff/libtiff.a" "$WORK/tiff-x86_64/libtiff/libtiff.a"

# --- Verifikation direkt im Build-Verzeichnis ---------------------------------
echo "→ Verifikation (lipo/nm) …"
lipo -info "$WORK/tiff-universal/lib/libtiff.a"
nm -gU "$WORK/tiff-universal/lib/libtiff.a" \
    | grep -E "_TIFFWriteScanline|_TIFFReadScanline|_TIFFSetField" | sort -u

# --- Nach Vendor ---------------------------------------------------------------
rm -rf "$DEST"
mkdir -p "$DEST/include" "$DEST/lib"
cp "$WORK/tiff-universal/lib/libtiff.a" "$DEST/lib/libtiff.a"

# Öffentliche Header: tiff.h/tiffio.h aus dem Quellbaum, tiffconf.h/tiffvers.h
# generiert (architekturunabhängig – Muster wie vendor-mozjpeg.sh).
cp "$SRC/libtiff/tiff.h" "$SRC/libtiff/tiffio.h" "$DEST/include/"
cp "$WORK/tiff-arm64/libtiff/tiffconf.h" \
   "$WORK/tiff-arm64/libtiff/tiffvers.h" "$DEST/include/"

# NOTICE: libtiff liefert LICENSE.md (BSD-artig, Sam Leffler / SGI).
{
    echo "# NOTICE – libtiff (vendored)"
    echo
    echo "Dieses Verzeichnis enthält eine statische, universelle Build-Artefakt-Kopie"
    echo "(arm64 + x86_64) von **libtiff v$VERSION**."
    echo
    echo "- Quelle: https://gitlab.com/libtiff/libtiff (Release \`v$VERSION\`,"
    echo "  Tarball https://download.osgeo.org/libtiff/tiff-$VERSION.tar.gz)"
    echo "- Lizenz: BSD-artig (Sam Leffler / Silicon Graphics), upstream \`LICENSE.md\`."
    echo "- Verwendung: CCITT G3/G4-Encoding (Fax-Codec) für Bilevel-PDF-Bilder"
    echo "  (COMPRESSION_ROADMAP.md, Phase 2). Keine Änderungen am Quellcode."
    echo "- Build-Konfiguration: Release, BUILD_SHARED_LIBS=OFF, tiff-cxx=OFF,"
    echo "  alle optionalen Codecs OFF (zlib/zstd/lzma/jpeg/webp/jbig/lerc/"
    echo "  libdeflate/pixarlog). CCITT-Fax-Codec default-ON. Deployment-Target"
    echo "  macOS 11.0. Tools/Tests/Docs nicht enthalten (verbleiben unter"
    echo "  /tmp/opencode)."
    echo
    echo "Original-Lizenztext:"
    echo
    cat "$SRC/LICENSE.md"
} > "$DEST/NOTICE-libtiff.md"

# --- Abschluss ------------------------------------------------------------------
echo
echo "✓ Vendored: $DEST"
ls -la "$DEST" "$DEST/lib" "$DEST/include"
lipo -info "$DEST/lib/libtiff.a"
