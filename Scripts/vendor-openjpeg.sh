#!/bin/bash
# Vendored OpenJPEG für PDFTools erzeugen (Roadmap Phase 4: JPX-DECODE).
#
# Kontext: JPX-Streams in INPUT-PDFs sollen dekodiert werden, um oversized
# JPX-Bilder downzusamplen und als JPEG (DCTDecode) bzw. Flate+Predictor neu
# zu kodieren. KEIN JPX-Output (PDFKit-Risiko, siehe COMPRESSION_ROADMAP.md
# "Nicht tun").
#
# Ergebnis: EINE universelle (arm64 + x86_64) STATISCHE libopenjpeg.a in
# Vendor/openjpeg – analog zu vendor-libtiff.sh (nur System-Abhängigkeiten,
# keine Dylibs, kein Homebrew auf dem Zielrechner):
#
#   Vendor/openjpeg/include/openjpeg-2.5/  openjpeg.h + generiertes opj_config.h
#                                          (die gesamte öffentliche API liegt in
#                                          openjpeg.h; opj_config_private.h/
#                                          opj_stdint.h sind intern und werden
#                                          upstream nicht installiert)
#   Vendor/openjpeg/lib/                   libopenjpeg.a (fett: arm64 + x86_64)
#   Vendor/openjpeg/                       NOTICE-openjpeg.md
#
# Die Codec-Tools (opj_compress/opj_decompress/opj_dump) werden mitgebaut
# (BUILD_CODEC=ON) und dienen dem Funktionstest unter /tmp/opencode – sie
# bleiben bewusst NICHT in Vendor (die App braucht nur die LIB).
#
# Aufruf:            ./Scripts/vendor-openjpeg.sh [--force]
# Standard-Version:  2.5.4 (aktuelles stabiles Release, github.com/uclouvain/
#                    openjpeg/releases, Aug 2026 ermittelt)
#
# Build-Konfiguration (minimal):
#   - BUILD_SHARED_LIBS=OFF, BUILD_STATIC_LIBS=ON → nur libopenjpeg.a
#   - BUILD_CODEC=ON (Tools nur für /tmp/opencode-Funktionstest)
#   - BUILD_TESTING=OFF, BUILD_DOC=OFF (hermetisch, schnell)
#   - Alle optionalen Drittanbieter-Suchen explizit deaktiviert via
#     CMAKE_DISABLE_FIND_PACKAGE_*: zlib, tiff, lcms, lcms2. PNG wird von
#     OpenJPEG nur gesucht, wenn ZLIB gefunden wurde – ohne ZLIB-Suche ist
#     der PNG-Pfad totes Code (daher keine eigene Flag nötig).
#     Entscheidung dokumentiert: Diese Libs werden in OpenJPEG ausschließlich
#     für die Bild-IO der Codec-TOOLS (PNG/TIFF) und das Farbmanagement der
#     JP2-Tools (lcms: SYCC/ICC-Transform) gesucht. Der Kern (libopenjp2)
#     benötigt nur libm. Ohne lcms ist die ICC-/SYCC-Farbtransformation der
#     TOOLS deaktiviert – das Dekodieren selbst (und gerade rohe J2K-
#     Codestreams, wie sie PDF /JPXDecode enthält) ist davon unberührt: die
#     LIB führt dort ohnehin keine Farbkonvertierung durch. PDF-seitig kommt
#     die Farbinformation aus /ColorSpace des Image-Dicts. Hermetischer
#     Nachweis: nm/otool im Funktionstest (keine undefined refs auf zlib/
#     lcms/png/tiff).

set -euo pipefail

VERSION="2.5.4"
WORK="/tmp/opencode/pdftools-vendor"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Vendor/openjpeg"
CM="$WORK/cmake-app/CMake.app/Contents/bin/cmake"
SRC="$WORK/openjpeg-$VERSION"

# --- Argumente: --force erzwingt Neubau ---------------------------------------
FORCE=0
for ARG in "$@"; do
    case "$ARG" in
        --force) FORCE=1 ;;
        *) echo "Unbekanntes Argument: $ARG (erlaubt: --force)" >&2; exit 1 ;;
    esac
done

if [ "$FORCE" -eq 0 ] && [ -f "$DEST/lib/libopenjpeg.a" ]; then
    echo "✓ Vendor/openjpeg existiert bereits – Skip (Neubau mit --force)."
    lipo -info "$DEST/lib/libopenjpeg.a"
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
    echo "→ Lade OpenJPEG $VERSION …"
    curl -sL --max-time 300 -o "$WORK/openjpeg-src.tar.gz" \
        "https://github.com/uclouvain/openjpeg/archive/refs/tags/v$VERSION.tar.gz"
    tar xzf "$WORK/openjpeg-src.tar.gz" -C "$WORK"
fi

# --- OpenJPEG: pro Architektur statisch bauen, dann .a mergen -------------------
# Muster aus vendor-libtiff.sh: beide Architekturen einzeln mit
# CMAKE_OSX_ARCHITECTURES, danach libtool -static zum Fat-Archiv.
echo "→ Baue OpenJPEG $VERSION (arm64 + x86_64, statisch, Kern ohne externe Deps) …"
for ARCH in arm64 x86_64; do
    if [ "$FORCE" -eq 1 ] || [ ! -f "$WORK/openjpeg-$ARCH/bin/libopenjp2.a" ]; then
        "$CM" -S "$SRC" -B "$WORK/openjpeg-$ARCH" \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_OSX_ARCHITECTURES=$ARCH \
            -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0 \
            -DCMAKE_INSTALL_PREFIX="$WORK/openjpeg-install-$ARCH" \
            -DBUILD_SHARED_LIBS=OFF \
            -DBUILD_STATIC_LIBS=ON \
            -DBUILD_CODEC=ON \
            -DBUILD_TESTING=OFF \
            -DBUILD_DOC=OFF \
            -DCMAKE_DISABLE_FIND_PACKAGE_ZLIB=TRUE \
            -DCMAKE_DISABLE_FIND_PACKAGE_TIFF=TRUE \
            -DCMAKE_DISABLE_FIND_PACKAGE_LCMS=TRUE \
            -DCMAKE_DISABLE_FIND_PACKAGE_LCMS2=TRUE > /dev/null
        "$CM" --build "$WORK/openjpeg-$ARCH" --parallel > /dev/null
        "$CM" --install "$WORK/openjpeg-$ARCH" > /dev/null
    fi
done

# Upstream heißt das statische Target-Archiv libopenjp2.a (Target "openjp2");
# nach Vendor wird es dokumentiert als libopenjpeg.a kopiert (Muster wie
# vendor-jbig2enc.sh: liblibjbig2enc.a).
mkdir -p "$WORK/openjpeg-universal/lib" "$WORK/openjpeg-universal/bin"
libtool -static -o "$WORK/openjpeg-universal/lib/libopenjp2.a" \
    "$WORK/openjpeg-arm64/bin/libopenjp2.a" "$WORK/openjpeg-x86_64/bin/libopenjp2.a"

# Universal-Tools nur nach /tmp (Funktionstest Phase 4b-Vorbereitung), NICHT
# nach Vendor – die App linkt die LIB, kein Shellexec.
for TOOL in opj_compress opj_decompress opj_dump; do
    lipo -create -output "$WORK/openjpeg-universal/bin/$TOOL" \
        "$WORK/openjpeg-arm64/bin/$TOOL" "$WORK/openjpeg-x86_64/bin/$TOOL"
done

# --- Verifikation direkt im Build-Verzeichnis ---------------------------------
echo "→ Verifikation (lipo/nm) …"
lipo -info "$WORK/openjpeg-universal/lib/libopenjp2.a"
nm -gU "$WORK/openjpeg-universal/lib/libopenjp2.a" \
    | grep -E "_opj_create_decompress$|_opj_decode$|_opj_read_header$|_opj_set_decode_area$" | sort -u

# Hermetie-Nachweis: Kernbibliothek darf keine undefined refs auf zlib/png/
# tiff/lcms enthalten (nur System-Symbols wie _malloc/_free/_pow bleiben).
UNDEF=$(nm -u "$WORK/openjpeg-universal/lib/libopenjp2.a" | grep -iE "lcms|png_|tiff_|inflate|deflate" || true)
if [ -n "$UNDEF" ]; then
    echo "✗ Unerwartete Abhängigkeiten in libopenjp2.a:" >&2
    echo "$UNDEF" >&2
    exit 1
fi
echo "✓ Keine Referenzen auf zlib/png/tiff/lcms in libopenjp2.a."

# --- Nach Vendor ---------------------------------------------------------------
rm -rf "$DEST"
mkdir -p "$DEST/lib"
# Include-Unterverzeichnis aus dem Install-Präfix übernehmen (upstream legt
# die Header unter include/openjpeg-2.5/ ab, Major.Minor ohne Patch);
# architekturunabhängig, daher Kopie aus dem arm64-Präfix.
INC_SUBDIR="$(cd "$WORK/openjpeg-install-arm64/include" && ls -d openjpeg-*)"
mkdir -p "$DEST/include/$INC_SUBDIR"
cp "$WORK/openjpeg-install-arm64/include/$INC_SUBDIR/"*.h \
    "$DEST/include/$INC_SUBDIR/"
cp "$WORK/openjpeg-universal/lib/libopenjp2.a" "$DEST/lib/libopenjpeg.a"

# NOTICE: BSD-2-Klausel. Die upstream LICENSE enthält zusätzlich den Hinweis,
# dass "third party and contributor rights, including patent rights" NICHT
# unter dieser Lizenz gewährt werden (kein separater MOF-/Microsoft-Patent-
# absatz in 2.5.4 – geprüft; der allgemeine Vorbehalt steht im Kopf der Datei
# und ist unten im Volltext enthalten).
{
    echo "# NOTICE – OpenJPEG (vendored)"
    echo
    echo "Dieses Verzeichnis enthält eine statische, universelle Build-Artefakt-Kopie"
    echo "(arm64 + x86_64) von **OpenJPEG v$VERSION**."
    echo
    echo "- Quelle: https://github.com/uclouvain/openjpeg (Tag \`v$VERSION\`,"
    echo "  Tarball https://github.com/uclouvain/openjpeg/archive/refs/tags/v$VERSION.tar.gz)"
    echo "- Lizenz: BSD-2-Klausel (upstream \`LICENSE\`, Volltext unten)."
    echo "- Verwendung: Dekodierung von \`/JPXDecode\`-Streams (JPEG 2000 rohe"
    echo "  Codestreams + JP2-Container) für die Neukompression oversized JPX-"
    echo "  Bilder (COMPRESSION_ROADMAP.md, Phase 4). Ausdrücklich NUR Dekodier-"
    echo "  pfad: kein JPX-Output (PDFKit-Risiko). Keine Änderungen am Quellcode."
    echo "- Build-Konfiguration: Release, BUILD_SHARED_LIBS=OFF,"
    echo "  BUILD_STATIC_LIBS=ON, BUILD_CODEC=ON (Tools verbleiben unter"
    echo "  /tmp/opencode), BUILD_TESTING=OFF, BUILD_DOC=OFF. Alle optionalen"
    echo "  Drittanbieter-Bibliotheken deaktiviert (zlib/png/tiff/lcms/lcms2) –"
    echo "  der Kern braucht nur libm; Konsequenz: Farbmanagement (lcms) der"
    echo "  JP2-Tools ist aus, rohe Codestream-Dekodierung unberührt."
    echo "  Deployment-Target macOS 11.0."
    echo
    echo "Original-Lizenztext:"
    echo
    echo '```'
    cat "$SRC/LICENSE"
    echo '```'
} > "$DEST/NOTICE-openjpeg.md"

# --- Abschluss ------------------------------------------------------------------
echo
echo "✓ Vendored: $DEST"
ls -la "$DEST" "$DEST/lib" "$DEST/include/$INC_SUBDIR"
lipo -info "$DEST/lib/libopenjpeg.a"
