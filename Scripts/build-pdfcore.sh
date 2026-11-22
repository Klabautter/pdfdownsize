#!/bin/bash
# Baut die C-Bridge Vendor/pdfcore/lib/libpdfcore.a (nur arm64).
#
# Beim Arbeiten an der Bridge ändert sich nur pdfcore.cc – dieses Skript
# kompiliert diese Übersetzungseinheit neu und packt sie mit allen
# vorgebauten Bibliotheken in EIN Archiv. Die App linkt nur noch
# -lpdfcore (plus -lc++ -lz aus dem System).
#
# Voraussetzung: vendor-qpdf.sh lief mindestens einmal, sodass libqpdf.a,
# libzopfli.a und die qpdf-Header im Arbeitsverzeichnis liegen. Fehlen sie,
# verweist das Skript auf den vollständigen Vendor-Lauf, statt still etwas
# Halbfertiges zu bauen.
set -euo pipefail
source "$(dirname "$0")/vendor-common.sh"

CORE_SRC="$VENDOR_ROOT/Vendor/pdfcore/src"
CORE_DEST="$VENDOR_ROOT/Vendor/pdfcore"

QPDF_LIB="$WORK/qpdf-build/libqpdf/libqpdf.a"
QPDF_HEADERS="$WORK/qpdf-headers"
ZOPFLI_DIR="$WORK/zopfli-$VENDOR_ARCH"

# mozjpeg ist die einzige JPEG-Implementierung (qpdf-DCT-Pfad und
# JPEGBackend teilen sie).
MOZJPEG_INC="$VENDOR_ROOT/Vendor/mozjpeg/include"
MOZJPEG_LIB="$VENDOR_ROOT/Vendor/mozjpeg/lib/libmozjpeg.a"
# libtiff (CCITT G4), jbig2enc + Leptonica (verlustfreies JBIG2). Reihenfolge
# im Archiv: jbig2enc VOR Leptonica (jbig2enc referenziert Leptonica).
TIFF_INC="$VENDOR_ROOT/Vendor/libtiff/include"
TIFF_LIB="$VENDOR_ROOT/Vendor/libtiff/lib/libtiff.a"
JBIG2_INC="$VENDOR_ROOT/Vendor/jbig2enc/include"
LEPT_INC="$VENDOR_ROOT/Vendor/jbig2enc/include/leptonica"
JBIG2_LIB="$VENDOR_ROOT/Vendor/jbig2enc/lib/libjbig2enc.a"
LEPT_LIB="$VENDOR_ROOT/Vendor/jbig2enc/lib/libleptonica.a"
# OpenJPEG – nur Dekodierung von JPX-Eingaben.
OPENJP_INC="$VENDOR_ROOT/Vendor/openjpeg/include/openjpeg-2.5"
OPENJP_LIB="$VENDOR_ROOT/Vendor/openjpeg/lib/libopenjpeg.a"
# HarfBuzz (Kern + Subsetter in einem Archiv) für Font-Subsetting.
HB_INC="$VENDOR_ROOT/Vendor/harfbuzz/include/hb"
HB_LIB="$VENDOR_ROOT/Vendor/harfbuzz/lib/libharfbuzz.a"
# libdeflate für schnelles, kompaktes RFC-1950-zlib in Flate-Bildströmen.
LIBDEFLATE_INC="$VENDOR_ROOT/Vendor/libdeflate/include"
LIBDEFLATE_LIB="$VENDOR_ROOT/Vendor/libdeflate/lib/libdeflate.a"

if [ ! -f "$QPDF_LIB" ] || [ ! -d "$QPDF_HEADERS" ] || [ ! -f "$ZOPFLI_DIR/libzopfli.a" ]; then
    echo "FEHLER: qpdf-Buildartefakte fehlen unter $WORK."
    echo "        Einmalig 'Scripts/vendor-qpdf.sh' ausführen."
    exit 1
fi
for lib in "$MOZJPEG_LIB" "$TIFF_LIB" "$JBIG2_LIB" "$LEPT_LIB" "$OPENJP_LIB" "$HB_LIB" "$LIBDEFLATE_LIB"; do
    if [ ! -f "$lib" ]; then
        echo "FEHLER: $lib fehlt."
        echo "        Einmalig die Scripts/vendor-*.sh-Skripte ausführen."
        exit 1
    fi
done
require_arm64_only "$QPDF_LIB" "$ZOPFLI_DIR/libzopfli.a" "$MOZJPEG_LIB" \
    "$TIFF_LIB" "$JBIG2_LIB" "$LEPT_LIB" "$OPENJP_LIB" "$HB_LIB" "$LIBDEFLATE_LIB"

CLANGXX="$(xcrun --find clang++)"
SDK_PATH="$(xcrun --show-sdk-path)"

# Quell-Hash: SHA-256 über pdfcore.cc gefolgt von pdfcore.h. Die Bibliothek
# meldet ihn über pdfcore_source_hash(); Hygiene-Test und verify-pdfcore.sh
# vergleichen ihn mit dem aktuellen Quelltext.
SOURCE_HASH="$(cat "$CORE_SRC/pdfcore.cc" "$CORE_SRC/pdfcore.h" | shasum -a 256 | cut -d' ' -f1)"

echo "→ Kompiliere pdfcore.cc ($VENDOR_ARCH, Quelle ${SOURCE_HASH:0:12}) …"
"$CLANGXX" -std=c++17 -O2 \
    -DPDFCORE_SOURCE_HASH="\"$SOURCE_HASH\"" \
    -arch "$VENDOR_ARCH" \
    -mmacosx-version-min="$VENDOR_DEPLOYMENT_TARGET" \
    -isysroot "$SDK_PATH" \
    -I"$CORE_SRC" -I"$QPDF_HEADERS" -I"$MOZJPEG_INC" \
    -I"$TIFF_INC" -I"$JBIG2_INC" -I"$LEPT_INC" -I"$OPENJP_INC" \
    -I"$HB_INC" -I"$LIBDEFLATE_INC" -I"$ZOPFLI_DIR/include" \
    -c "$CORE_SRC/pdfcore.cc" -o "$WORK/pdfcore.o"

echo "→ Linke libpdfcore.a (Bridge + qpdf + mozjpeg + Fax/JBIG2/JPX/HarfBuzz/libdeflate) …"
mkdir -p "$CORE_DEST/lib" "$CORE_DEST/include/pdfcore"
rm -f "$CORE_DEST/lib/libpdfcore_universal.a" "$CORE_DEST/lib/libjpeg_universal.a"
libtool -static -o "$CORE_DEST/lib/libpdfcore.a" \
    "$WORK/pdfcore.o" "$QPDF_LIB" "$MOZJPEG_LIB" "$TIFF_LIB" "$JBIG2_LIB" \
    "$LEPT_LIB" "$ZOPFLI_DIR/libzopfli.a" "$OPENJP_LIB" "$HB_LIB" "$LIBDEFLATE_LIB"
# libqpdf ist mit Zopfli übersetzt – ohne libzopfli.a scheitert der App-Link
# an undefinierten Zopfli-Symbolen.

cp "$CORE_SRC/pdfcore.h" "$CORE_DEST/include/pdfcore/"

require_arm64_only "$CORE_DEST/lib/libpdfcore.a"
echo "✓ pdfcore aktualisiert"
