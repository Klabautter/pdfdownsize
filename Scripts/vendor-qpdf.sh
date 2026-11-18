#!/bin/bash
# Vendored qpdf für PDFdownsize erzeugen.
#
# Ergebnis:
#   - Vendor/qpdf/qpdf: statisch gelinkte qpdf-Binärdatei (nur arm64), nur
#     System-Abhängigkeiten (libz, libc++, libSystem). Wird als Helfer ins
#     App-Bundle kopiert.
#   - libqpdf.a, libzopfli.a und die qpdf-Header im Arbeitsverzeichnis, aus
#     denen build-pdfcore.sh die Bridge-Bibliothek libpdfcore.a baut.
#
# Aufruf:  ./Scripts/vendor-qpdf.sh
#
# Voraussetzung: Vendor/mozjpeg (Scripts/vendor-mozjpeg.sh) und die übrigen
# Vendor-Bibliotheken für den abschließenden Bridge-Build.
#
# Build-Konfiguration:
#   - statisches libqpdf, native Crypto (kein OpenSSL/GnuTLS)
#   - JPEG über mozjpeg: eine JPEG-Implementierung für qpdf und App
#   - Zopfli: qpdf mit -DZOPFLI=ON; zopfli (Repo archiviert, Commit gepinnt,
#     nach Tag zopfli-1.0.3) als statische libzopfli.a. Aktivierung zur
#     Laufzeit ausschließlich per QPDF_ZOPFLI=silent|force.

set -euo pipefail
source "$(dirname "$0")/vendor-common.sh"

VERSION="12.4.0"
DEST="$VENDOR_ROOT/Vendor/qpdf"
MOZJPEG_INC="$VENDOR_ROOT/Vendor/mozjpeg/include"
MOZJPEG_LIB="$VENDOR_ROOT/Vendor/mozjpeg/lib/libmozjpeg.a"
ZOPFLI_COMMIT="ccf9f0588d4a4509cb1040310ec122243e670ee6"
ZOPFLI_SRC="$WORK/zopfli-$ZOPFLI_COMMIT"
ZOPFLI_OUT="$WORK/zopfli-$VENDOR_ARCH"
QPDF_SRC="$WORK/qpdf-$VERSION"
QPDF_BUILD="$WORK/qpdf-build"

if [ ! -f "$MOZJPEG_LIB" ]; then
    echo "FEHLER: $MOZJPEG_LIB fehlt."
    echo "        Einmalig 'Scripts/vendor-mozjpeg.sh' ausführen."
    exit 1
fi

ensure_cmake
fetch_verified "qpdf-$VERSION.tar.gz" "$QPDF_SRC"
fetch_verified "zopfli-$ZOPFLI_COMMIT.tar.gz" "$ZOPFLI_SRC"

# --- zopfli: statische Library ----------------------------------------------
# Alle src/zopfli/*.c außer zopfli_bin.c (Tool-main). Ausgabe libzopfli.a +
# include/zopfli/zopfli.h – genau das, was qpdf per find_path/find_library
# erwartet.
CLANG="$(xcrun --find clang)"
SDK_PATH="$(xcrun --show-sdk-path)"
echo "→ Baue zopfli ($VENDOR_ARCH, statisch) …"
rm -rf "$ZOPFLI_OUT"
mkdir -p "$ZOPFLI_OUT/obj" "$ZOPFLI_OUT/include/zopfli"
for f in "$ZOPFLI_SRC"/src/zopfli/*.c; do
    base="$(basename "$f" .c)"
    [ "$base" = "zopfli_bin" ] && continue
    "$CLANG" -Os -mmacosx-version-min="$VENDOR_DEPLOYMENT_TARGET" \
        -arch "$VENDOR_ARCH" -isysroot "$SDK_PATH" \
        -I"$ZOPFLI_SRC/src/zopfli" \
        -c "$f" -o "$ZOPFLI_OUT/obj/$base.o"
done
libtool -static -o "$ZOPFLI_OUT/libzopfli.a" "$ZOPFLI_OUT"/obj/*.o
cp "$ZOPFLI_SRC/src/zopfli/zopfli.h" "$ZOPFLI_OUT/include/zopfli/"
require_arm64_only "$ZOPFLI_OUT/libzopfli.a"

# --- qpdf: statisch, native Crypto, mit Zopfli -------------------------------
echo "→ Baue qpdf $VERSION ($VENDOR_ARCH, statisch, Zopfli) …"
rm -rf "$QPDF_BUILD"
"$CM" -S "$QPDF_SRC" -B "$QPDF_BUILD" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES="$VENDOR_ARCH" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$VENDOR_DEPLOYMENT_TARGET" \
    -DBUILD_SHARED_LIBS=OFF -DBUILD_STATIC_LIBS=ON \
    -DUSE_IMPLICIT_CRYPTO=OFF -DREQUIRE_CRYPTO_NATIVE=ON \
    -DBUILD_DOC=OFF -DBUILD_TESTING=OFF \
    -DLIBJPEG_H_PATH="$MOZJPEG_INC" \
    -DLIBJPEG_LIB_PATH="$MOZJPEG_LIB" \
    -DZOPFLI=ON \
    -DZOPFLI_H_PATH="$ZOPFLI_OUT/include/zopfli" \
    -DZOPFLI_LIB_PATH="$ZOPFLI_OUT/libzopfli.a" > /dev/null
"$CM" --build "$QPDF_BUILD" --parallel > /dev/null

BIN="$QPDF_BUILD/qpdf/qpdf"
require_arm64_only "$BIN" "$QPDF_BUILD/libqpdf/libqpdf.a"
if otool -L "$BIN" | grep -qE '/opt/homebrew|/usr/local/'; then
    echo "FEHLER: qpdf linkt gegen Homebrew-Bibliotheken." >&2
    exit 1
fi

rm -f "$DEST"/qpdf "$DEST"/*.dylib "$DEST/LICENSE-libjpeg-turbo.md"
mkdir -p "$DEST"
cp "$BIN" "$DEST/qpdf"
chmod +x "$DEST/qpdf"
cp "$QPDF_SRC/LICENSE.txt"                       "$DEST/LICENSE-qpdf.txt"
cp "$QPDF_SRC/NOTICE.md"                         "$DEST/NOTICE-qpdf.md"
cp "$VENDOR_ROOT/Vendor/mozjpeg/LICENSE-mozjpeg.md" "$DEST/LICENSE-libjpeg-mozjpeg.md"
cp "$ZOPFLI_SRC/COPYING"                         "$DEST/LICENSE-zopfli.txt"
codesign --force --sign - "$DEST/qpdf"

# --- Header für die Bridge ---------------------------------------------------
rm -rf "$WORK/qpdf-headers"
mkdir -p "$WORK/qpdf-headers/qpdf"
cp "$QPDF_SRC"/include/qpdf/*.h "$QPDF_SRC"/include/qpdf/*.hh "$WORK/qpdf-headers/qpdf/"
find "$QPDF_BUILD" \( -name "qpdf-config.h" -o -name "QPDFVersion.h" \) \
    -exec cp {} "$WORK/qpdf-headers/qpdf/" \;

# Dieselbe Bridge wie bei inkrementellen Builds.
"$VENDOR_ROOT/Scripts/build-pdfcore.sh"

echo
echo "✓ Vendored: $DEST"
"$DEST/qpdf" --version | head -1
