#!/bin/bash
# Vendored jbig2enc + Leptonica für PDFTools erzeugen (Roadmap Phase 2:
# lossless JBIG2-Encoding).
#
# Ergebnis: UNIVERSelle (arm64 + x86_64) STATISCHE Archive in Vendor/jbig2enc –
# analog zu vendor-mozjpeg.sh (nur System-Abhängigkeiten, keine Dylibs):
#
#   Vendor/jbig2enc/include/             jbig2enc.h
#   Vendor/jbig2enc/include/leptonica/   Leptonica-Header (allheaders.h, …)
#   Vendor/jbig2enc/lib/                 libjbig2enc.a + libleptonica.a (fett)
#   Vendor/jbig2enc/                     NOTICE-jbig2enc.md (beide Lizenzen)
#
# Das CLI-Tool `jbig2` wird nur unter /tmp/opencode gebaut (Funktionstest) –
# bewusst NICHT nach Vendor (kein Tool-Binary im App-Bundle; Phase 2b linkt
# die LIB, kein Shellexec).
#
# Aufruf:            ./Scripts/vendor-jbig2enc.sh [--force]
# Standard-Version:  Leptonica 1.87.0 (aktuelles stabiles Release Aug 2026);
#                    jbig2enc Master-Commit 23f992c (Aug 2026, kein Release-
#                    Tag – Commit gepinnt für Reproduzierbarkeit).
#
# Abhängigkeits-Reihenfolge: Leptonica ZUERST (per CMake in ein Install-
# Präfix je Architektur), danach jbig2enc mit -DCMAKE_PREFIX_PATH darauf
# (find_package(Leptonica CONFIG)).
#
# Build-Konfiguration Leptonica (kleinste funktionierende Kombi):
#   - BUILD_SHARED_LIBS=0, BUILD_PROG=0, SW_BUILD=0
#   - ALLE optionalen Codecs OFF (ZLIB/PNG/GIF/JPEG/TIFF/WEBP/OPENJPEG):
#     jbig2enc nutzt nur pixCreate/pixGet*/pixSetPixel/pixWrite(BMP) –
#     BMP/PNM-Codecs sind in Leptonica eingebaut ohne externe Libs;
#     pixReadTiff existiert als Stub (tiffiostub.c) → CLI linkt sauber.
#   - Ergebnis: libleptonica.a ohne externe Abhängigkeiten (nur libm).
#
# Build-Konfiguration jbig2enc:
#   - statische libjbig2enc.a (Target "libjbig2enc" → CMake erzeugt
#     "liblibjbig2enc.a", dokumentiert umbenannt)
#   - Refinement wird NICHT gebaut/aktiviert (CLI-Flag -r bleibt unbenutzt;
#     bekannter Acrobat-Crasher – Roadmap-Regel (b))

set -euo pipefail

LEPT_VERSION="1.87.0"
JB2_COMMIT="23f992c92b10048064602b4d8ea29bb434752634"
WORK="/tmp/opencode/pdftools-vendor"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Vendor/jbig2enc"
CM="$WORK/cmake-app/CMake.app/Contents/bin/cmake"
ARCHS="arm64;x86_64"
LEPT_SRC="$WORK/leptonica-$LEPT_VERSION"
JB2_SRC="$WORK/jbig2enc-$JB2_COMMIT"

# --- Argumente: --force erzwingt Neubau ---------------------------------------
FORCE=0
for ARG in "$@"; do
    case "$ARG" in
        --force) FORCE=1 ;;
        *) echo "Unbekanntes Argument: $ARG (erlaubt: --force)" >&2; exit 1 ;;
    esac
done

if [ "$FORCE" -eq 0 ] && [ -f "$DEST/lib/libjbig2enc.a" ]; then
    echo "✓ Vendor/jbig2enc existiert bereits – Skip (Neubau mit --force)."
    lipo -info "$DEST/lib/libjbig2enc.a"
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

if [ ! -d "$LEPT_SRC" ]; then
    echo "→ Lade Leptonica $LEPT_VERSION …"
    curl -sL --max-time 300 -o "$WORK/leptonica-src.tar.gz" \
        "https://github.com/DanBloomberg/leptonica/archive/refs/tags/$LEPT_VERSION.tar.gz"
    tar xzf "$WORK/leptonica-src.tar.gz" -C "$WORK"
fi

if [ ! -d "$JB2_SRC" ]; then
    echo "→ Lade jbig2enc @$JB2_COMMIT …"
    curl -sL --max-time 300 -o "$WORK/jbig2enc-src.tar.gz" \
        "https://github.com/agl/jbig2enc/archive/$JB2_COMMIT.tar.gz"
    tar xzf "$WORK/jbig2enc-src.tar.gz" -C "$WORK"
fi

# --- Leptonica: pro Architektur statisch bauen + installieren ------------------
echo "→ Baue Leptonica $LEPT_VERSION (arm64 + x86_64, statisch, ohne Codecs) …"
for ARCH in arm64 x86_64; do
    if [ "$FORCE" -eq 1 ] || [ ! -f "$WORK/lept-$ARCH/src/libleptonica.a" ]; then
        "$CM" -S "$LEPT_SRC" -B "$WORK/lept-$ARCH" \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_OSX_ARCHITECTURES=$ARCH \
            -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0 \
            -DCMAKE_INSTALL_PREFIX="$WORK/leptonica-install-$ARCH" \
            -DBUILD_SHARED_LIBS=OFF \
            -DBUILD_PROG=OFF -DSW_BUILD=OFF \
            -DENABLE_ZLIB=OFF -DENABLE_PNG=OFF -DENABLE_GIF=OFF \
            -DENABLE_JPEG=OFF -DENABLE_TIFF=OFF -DENABLE_WEBP=OFF \
            -DENABLE_OPENJPEG=OFF > /dev/null
        "$CM" --build "$WORK/lept-$ARCH" --parallel > /dev/null
        "$CM" --install "$WORK/lept-$ARCH" > /dev/null
    fi
done

mkdir -p "$WORK/jbig2enc-universal/lib" "$WORK/jbig2enc-universal/bin"
libtool -static -o "$WORK/jbig2enc-universal/lib/libleptonica.a" \
    "$WORK/lept-arm64/src/libleptonica.a" "$WORK/lept-x86_64/src/libleptonica.a"

# --- jbig2enc: pro Architektur statisch bauen, dann .a + CLI mergen ------------
# CLI linkt je Architektur gegen die passende statische Leptonica
# (Install-Präfix je Arch, siehe oben).
echo "→ Baue jbig2enc @$JB2_COMMIT (arm64 + x86_64, statisch) …"
for ARCH in arm64 x86_64; do
    if [ "$FORCE" -eq 1 ] || [ ! -f "$WORK/jb2-$ARCH/liblibjbig2enc.a" ]; then
        "$CM" -S "$JB2_SRC" -B "$WORK/jb2-$ARCH" \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_OSX_ARCHITECTURES=$ARCH \
            -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0 \
            -DBUILD_SHARED_LIBS=OFF \
            -DCMAKE_PREFIX_PATH="$WORK/leptonica-install-$ARCH" > /dev/null
        "$CM" --build "$WORK/jb2-$ARCH" --parallel > /dev/null
    fi
done

libtool -static -o "$WORK/jbig2enc-universal/lib/libjbig2enc.a" \
    "$WORK/jb2-arm64/liblibjbig2enc.a" "$WORK/jb2-x86_64/liblibjbig2enc.a"

# Universal-CLI nur nach /tmp (Funktionstest Phase 2a), NICHT nach Vendor.
lipo -create -output "$WORK/jbig2enc-universal/bin/jbig2" \
    "$WORK/jb2-arm64/jbig2" "$WORK/jb2-x86_64/jbig2"

# --- Verifikation direkt im Build-Verzeichnis ---------------------------------
echo "→ Verifikation (lipo/nm) …"
lipo -info "$WORK/jbig2enc-universal/lib/libleptonica.a" \
           "$WORK/jbig2enc-universal/lib/libjbig2enc.a"
# jbig2enc ist C++: nm-Ausgabe via c++filt demanglen, dann API-Symbole prüfen.
nm -gU "$WORK/jbig2enc-universal/lib/libjbig2enc.a" | c++filt \
    | grep -E "jbig2_init\(|jbig2_add_page\(|jbig2_pages_complete\(|jbig2_produce_page\(|jbig2_encode_generic\(" \
    | sort -u
nm -gU "$WORK/jbig2enc-universal/lib/libleptonica.a" \
    | grep -E "_pixCreate$|_pixDestroy$|_pixWrite$" | sort -u

# --- Nach Vendor ---------------------------------------------------------------
rm -rf "$DEST"
mkdir -p "$DEST/include/leptonica" "$DEST/lib"
cp "$WORK/jbig2enc-universal/lib/libjbig2enc.a" "$DEST/lib/libjbig2enc.a"
cp "$WORK/jbig2enc-universal/lib/libleptonica.a" "$DEST/lib/libleptonica.a"

# Header: jbig2enc-API (jbig2enc.h – vollständige öffentliche Schnittstelle)
# + Leptonica-Header aus dem Install-Präfix (inkl. generiertem endianness.h).
cp "$JB2_SRC/src/jbig2enc.h" "$DEST/include/"
cp "$WORK/leptonica-install-arm64/include/leptonica/"*.h "$DEST/include/leptonica/"

# NOTICE: beide Lizenzen (jbig2enc: Apache-2.0, Leptonica: BSD-artig gemäß
# upstream leptonica-license.txt).
{
    echo "# NOTICE – jbig2enc + Leptonica (vendored)"
    echo
    echo "Dieses Verzeichnis enthält statische, universelle Build-Artefakt-Kopien"
    echo "(arm64 + x86_64) von:"
    echo
    echo "1. **jbig2enc**, Commit \`$JB2_COMMIT\` (Master-Stand Aug 2026, kein"
    echo "   Release-Tag – Commit gepinnt)"
    echo "   Quelle: https://github.com/agl/jbig2enc"
    echo "   Lizenz: Apache-2.0 (upstream \`COPYING\`, siehe unten)"
    echo
    echo "2. **Leptonica v$LEPT_VERSION**"
    echo "   Quelle: https://github.com/DanBloomberg/leptonica (Tag \`$LEPT_VERSION\`)"
    echo "   Lizenz: BSD-artig (upstream \`leptonica-license.txt\`, siehe unten)"
    echo
    echo "Verwendung: lossless JBIG2-Encoding für Bilevel-PDF-Bilder"
    echo "(COMPRESSION_ROADMAP.md, Phase 2). Keine Änderungen am Quellcode."
    echo "Regeln: NUR lossless, KEIN Refinement (CLI \`-r\` unbenutzt; bekannter"
    echo "Acrobat-Crasher). Das CLI \`jbig2\` ist NICHT Teil dieses Verzeichnisses"
    echo "(verbleibt unter /tmp/opencode)."
    echo
    echo "Build-Konfiguration: Release, BUILD_SHARED_LIBS=OFF. Leptonica mit ALLEN"
    echo "optionalen Codecs OFF (zlib/png/gif/jpeg/tiff/webp/openjpeg) – BMP/PNM"
    echo "sind eingebaut; jbig2enc benötigt nur die Pix-Kern-API. Deployment-Target"
    echo "macOS 11.0. Nur System-Abhängigkeiten (libm)."
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

# --- Abschluss ------------------------------------------------------------------
echo
echo "✓ Vendored: $DEST"
ls -la "$DEST" "$DEST/lib" "$DEST/include"
lipo -info "$DEST/lib/libjbig2enc.a" "$DEST/lib/libleptonica.a"
"$WORK/jbig2enc-universal/bin/jbig2" -V 2>&1 | head -2 || true
