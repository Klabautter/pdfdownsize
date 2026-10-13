#!/bin/bash
# Inkrementeller Rebuild NUR der C-Bridge (Vendor/pdfcore/src/pdfcore.cc).
#
# `vendor-qpdf.sh` lädt und baut die komplette qpdf-Toolchain neu (Minuten).
# Beim Arbeiten an der Bridge ändert sich aber ausschließlich pdfcore.cc –
# dieses Skript kompiliert nur diese Übersetzungseinheit neu und linkt sie
# gegen die bereits gebaute libqpdf.a.
#
# Voraussetzung: vendor-qpdf.sh wurde mindestens einmal ausgeführt, sodass
# $WORK/qpdf-build/libqpdf/libqpdf.a und $WORK/qpdf-headers existieren.
# Fehlen sie, verweist das Skript auf den vollständigen Vendor-Lauf, statt
# still etwas Halbfertiges zu produzieren.
set -euo pipefail

WORK="/tmp/opencode/pdftools-vendor"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CORE_SRC="$ROOT/Vendor/pdfcore/src"
CORE_DEST="$ROOT/Vendor/pdfcore"

QPDF_LIB="$WORK/qpdf-build/libqpdf/libqpdf.a"
QPDF_HEADERS="$WORK/qpdf-headers"

# Phase 1b: mozjpeg ERSETZT libjpeg-turbo als EINZIGE JPEG-Implementierung im
# App-Binary (gleiche ABI 62, Superset-Symbole – siehe
# Vendor/mozjpeg/INTEGRATION_NOTES.md). Die Headers sitzen neben der Lib,
# die App linkt das Artefakt unter dem bekannten Namen libjpeg_universal.a.
MOZJPEG_INC="$ROOT/Vendor/mozjpeg/include"
MOZJPEG_LIB="$ROOT/Vendor/mozjpeg/lib/libmozjpeg.a"

# Phase 2b: libtiff (CCITT G4) sowie jbig2enc + Leptonica (lossless JBIG2)
# wandern MIT in die pdfcore-Statik. Reihenfolge im Archiv: jbig2enc VOR
# Leptonica (jbig2enc referenziert Leptonica-Symbole), libtiff ohne externe
# Abhängigkeiten. Alle drei sind statisch und universell (arm64 + x86_64),
# siehe Vendor/*/NOTICE-*.md.
TIFF_INC="$ROOT/Vendor/libtiff/include"
TIFF_LIB="$ROOT/Vendor/libtiff/lib/libtiff.a"
JBIG2_INC="$ROOT/Vendor/jbig2enc/include"
LEPT_INC="$ROOT/Vendor/jbig2enc/include/leptonica"
JBIG2_LIB="$ROOT/Vendor/jbig2enc/lib/libjbig2enc.a"
LEPT_LIB="$ROOT/Vendor/jbig2enc/lib/libleptonica.a"

# Phase 4b: OpenJPEG (JPEG2000) – NUR zur Dekodierung von JPX-Eingaben,
# es gibt keinen Encode-Shim (JPX wird nie als Output geschrieben).
# Statisch und universell (arm64 + x86_64), siehe Vendor/openjpeg/NOTICE-openjpeg.md.
OPENJP_INC="$ROOT/Vendor/openjpeg/include/openjpeg-2.5"
OPENJP_LIB="$ROOT/Vendor/openjpeg/lib/libopenjpeg.a"

# Phase 5b: HarfBuzz (hb-subset) für Font-Subsetting. Statisch, universell,
# ohne glib/icu/cairo (Unicode über hb-ucd); Kern + Subsetter sind im
# Vendor-Skript bereits zu EINEM Archiv verschmolzen (hb-static-Dublette
# entfernt), siehe Vendor/harfbuzz/NOTICE-harfbuzz.md.
HB_INC="$ROOT/Vendor/harfbuzz/include/hb"
HB_LIB="$ROOT/Vendor/harfbuzz/lib/libharfbuzz.a"

if [ ! -f "$QPDF_LIB" ] || [ ! -d "$QPDF_HEADERS" ]; then
    echo "FEHLER: qpdf-Buildartefakte fehlen unter $WORK."
    echo "        Einmalig 'Scripts/vendor-qpdf.sh' ausführen."
    exit 1
fi
if [ ! -f "$MOZJPEG_LIB" ]; then
    echo "FEHLER: $MOZJPEG_LIB fehlt."
    echo "        Einmalig 'Scripts/vendor-mozjpeg.sh' ausführen."
    exit 1
fi
for lib in "$TIFF_LIB" "$JBIG2_LIB" "$LEPT_LIB" "$OPENJP_LIB" "$HB_LIB"; do
    if [ ! -f "$lib" ]; then
        echo "FEHLER: $lib fehlt."
        echo "        Einmalig 'Scripts/vendor-libtiff.sh', 'Scripts/vendor-jbig2enc.sh', 'Scripts/vendor-openjpeg.sh' und 'Scripts/vendor-harfbuzz.sh' ausführen."
        exit 1
    fi
done

CLANGXX="$(xcrun --find clang++)"
SDK_PATH="$(xcrun --show-sdk-path)"

echo "→ Kompiliere pdfcore.cc (arm64 + x86_64) …"
"$CLANGXX" -std=c++17 -O2 \
    -arch arm64 -arch x86_64 \
    -mmacosx-version-min=11.0 \
    -isysroot "$SDK_PATH" \
    -I"$CORE_SRC" -I"$QPDF_HEADERS" -I"$MOZJPEG_INC" \
    -I"$TIFF_INC" -I"$JBIG2_INC" -I"$LEPT_INC" -I"$OPENJP_INC" \
    -I"$HB_INC" -I"$WORK/zopfli-universal/include" \
    -c "$CORE_SRC/pdfcore.cc" -o "$WORK/pdfcore.o"

echo "→ Linke libpdfcore_universal.a (qpdf + mozjpeg-Freunde + Fax/JBIG2/JPX/HarfBuzz) …"
libtool -static -o "$CORE_DEST/lib/libpdfcore_universal.a" \
    "$WORK/pdfcore.o" "$QPDF_LIB" "$TIFF_LIB" "$JBIG2_LIB" "$LEPT_LIB" "$WORK/zopfli-universal/libzopfli.a" "$OPENJP_LIB" "$HB_LIB"
# libqpdf ist seit Phase 3a mit ZOPFLI-Makro kompiliert – ohne libzopfli.a
# würde der App-Link mit undefinierten Zopfli-Symbolen scheitern. OpenJPEG
# und HarfBuzz stehen am Ende: keine Abhängigkeiten außer libc/libm (libSystem).

# Das JPEG-Artefakt bleibt im Dateinamen stabil (Xcode-Link: -ljpeg_universal),
# der INHALT ist seit Phase 1b mozjpeg.
cp "$MOZJPEG_LIB" "$CORE_DEST/lib/libjpeg_universal.a"

cp "$CORE_SRC/pdfcore.h" "$CORE_DEST/include/pdfcore/"

lipo -info "$CORE_DEST/lib/libpdfcore_universal.a"
echo "✓ pdfcore aktualisiert"
