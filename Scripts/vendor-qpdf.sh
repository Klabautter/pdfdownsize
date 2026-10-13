#!/bin/bash
# Vendored qpdf für PDFTools erzeugen (Sprint F, Review §61–62 + Feedback #1).
#
# Ergebnis: EINE universelle (arm64 + x86_64) statisch gelinkte qpdf-Binärdatei
# in Vendor/qpdf – nur System-Abhängigkeiten (libz, libc++, libSystem).
# Kein Homebrew auf dem Zielrechner nötig.
#
# Aufruf:            ./Scripts/vendor-qpdf.sh [VERSION]
# Standard-Version:  12.4.0
#
# Voraussetzungen: Xcode-CLT (clang, make, libtool). CMake wird automatisch
# nach /tmp/opencode geladen (offizielles Universal-Release von Kitware).
#
# Build-Konfiguration:
#   - statisches libqpdf, native Crypto (kein OpenSSL/GnuTLS)
#   - JPEG über mozjpeg (Phase 1b): Vendor/mozjpeg/lib/libmozjpeg.a ERSETZT
#     die frühere selbst gebaute libjpeg-turbo-Lib – gleiche ABI (62,
#     Superset-Symbole), EINE JPEG-Implementierung im App-Binary
#   - Zopfli (Phase 3a): qpdf wird mit -DZOPFLI=ON gebaut. Die zopfli-Quellen
#     (github.com/google/zopfli, Repo archiviert und damit eingefroren,
#     gepinnt auf Master-Head ZOPFLI_COMMIT, nach Tag zopfli-1.0.3) werden
#     zusätzlich als universelle statische libzopfli.a übersetzt und in die
#     qpdf-Binärdatei sowie libpdfcore_universal.a eingebacken. Aktivierung
#     zur Laufzeit ausschließlich per QPDF_ZOPFLI=silent|force.
#   - keine Dylibs → kein install_name_tool-Gefummel mehr

set -euo pipefail

VERSION="${1:-12.4.0}"
WORK="/tmp/opencode/pdftools-vendor"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Vendor/qpdf"
MOZJPEG_INC="$ROOT/Vendor/mozjpeg/include"
MOZJPEG_LIB="$ROOT/Vendor/mozjpeg/lib/libmozjpeg.a"
CM="$WORK/cmake-app/CMake.app/Contents/bin/cmake"
ARCHS="arm64;x86_64"
# zopfli: Repo github.com/google/zopfli ist archiviert (eingefroren), Commit
# fest gepinnt statt Branch zu folgen. Liegt nach Tag zopfli-1.0.3 (2019),
# enthält dessen Korrekturen; Apache-2.0.
ZOPFLI_COMMIT="ccf9f0588d4a4509cb1040310ec122243e670ee6"
ZOPFLI_SRC="$WORK/zopfli-src"
ZOPFLI_OUT="$WORK/zopfli-universal"

mkdir -p "$WORK" "$DEST"

if [ ! -f "$MOZJPEG_LIB" ]; then
    echo "FEHLER: $MOZJPEG_LIB fehlt."
    echo "        Einmalig 'Scripts/vendor-mozjpeg.sh' ausführen."
    exit 1
fi

# --- Werkzeuge & Quellen besorgen -------------------------------------------
if [ ! -x "$CM" ]; then
    echo "→ Lade CMake (universal) …"
    curl -sL --max-time 300 -o "$WORK/cmake.tar.gz" \
        "https://github.com/Kitware/CMake/releases/download/v3.30.5/cmake-3.30.5-macos-universal.tar.gz"
    tar xzf "$WORK/cmake.tar.gz" -C "$WORK"
    mv "$WORK/cmake-3.30.5-macos-universal" "$WORK/cmake-app"
fi

if [ ! -d "$WORK/qpdf-$VERSION" ]; then
    echo "→ Lade qpdf $VERSION …"
    curl -sL --max-time 300 -o "$WORK/qpdf-src.tar.gz" \
        "https://github.com/qpdf/qpdf/releases/download/v$VERSION/qpdf-$VERSION.tar.gz"
    tar xzf "$WORK/qpdf-src.tar.gz" -C "$WORK"
fi

# --- zopfli: universelle statische Library (arm64 + x86_64) ------------------
# Zopfli ist schlichtes C; alle src/zopfli/*.c außer zopfli_bin.c (Tool-main)
# bilden die Library. Output: libzopfli.a + include/zopfli/zopfli.h – genau
# das, was qpdf per find_path(ZOPFLI_H_PATH)/find_library(ZOPFLI_LIB_PATH)
# erwartet.
if [ ! -d "$ZOPFLI_SRC" ]; then
    echo "→ Lade zopfli (Commit ${ZOPFLI_COMMIT:0:12}) …"
    curl -sL --max-time 300 -o "$WORK/zopfli-src.tar.gz" \
        "https://github.com/google/zopfli/archive/$ZOPFLI_COMMIT.tar.gz"
    tar xzf "$WORK/zopfli-src.tar.gz" -C "$WORK"
    mv "$WORK/zopfli-$ZOPFLI_COMMIT" "$ZOPFLI_SRC"
fi
CLANG="$(xcrun --find clang)"
SDK_PATH="$(xcrun --show-sdk-path)"
if [ ! -f "$ZOPFLI_OUT/libzopfli.a" ]; then
    echo "→ Baue zopfli (arm64 + x86_64, statisch) …"
    mkdir -p "$ZOPFLI_OUT/obj" "$ZOPFLI_OUT/include/zopfli"
    for f in "$ZOPFLI_SRC"/src/zopfli/*.c; do
        base="$(basename "$f" .c)"
        [ "$base" = "zopfli_bin" ] && continue
        "$CLANG" -Os -mmacosx-version-min=11.0 \
            -arch arm64 -arch x86_64 -isysroot "$SDK_PATH" \
            -I"$ZOPFLI_SRC/src/zopfli" \
            -c "$f" -o "$ZOPFLI_OUT/obj/$base.o"
    done
    libtool -static -o "$ZOPFLI_OUT/libzopfli.a" "$ZOPFLI_OUT"/obj/*.o
    cp "$ZOPFLI_SRC/src/zopfli/zopfli.h" "$ZOPFLI_OUT/include/zopfli/"
    lipo -info "$ZOPFLI_OUT/libzopfli.a"
fi

# --- qpdf: universal, statisch, native Crypto, mit Zopfli --------------------
echo "→ Baue qpdf $VERSION (arm64 + x86_64, statisch, Zopfli) …"
"$CM" -S "$WORK/qpdf-$VERSION" -B "$WORK/qpdf-build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES="$ARCHS" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0 \
    -DBUILD_SHARED_LIBS=OFF -DBUILD_STATIC_LIBS=ON \
    -DUSE_IMPLICIT_CRYPTO=OFF -DREQUIRE_CRYPTO_NATIVE=ON \
    -DBUILD_DOC=OFF -DBUILD_TESTING=OFF \
    -DLIBJPEG_H_PATH="$MOZJPEG_INC" \
    -DLIBJPEG_LIB_PATH="$MOZJPEG_LIB" \
    -DZOPFLI=ON \
    -DZOPFLI_H_PATH="$ZOPFLI_OUT/include/zopfli" \
    -DZOPFLI_LIB_PATH="$ZOPFLI_OUT/libzopfli.a" > /dev/null
"$CM" --build "$WORK/qpdf-build" --parallel > /dev/null

# --- Nach Vendor -------------------------------------------------------------
BIN="$WORK/qpdf-build/qpdf/qpdf"
lipo -info "$BIN"
otool -L "$BIN" | sed -n '2,5p'

rm -f "$DEST"/qpdf "$DEST"/*.dylib
cp "$BIN" "$DEST/qpdf"
chmod +x "$DEST/qpdf"

cp "$WORK/qpdf-$VERSION/LICENSE.txt"     "$DEST/LICENSE-qpdf.txt"
cp "$WORK/qpdf-$VERSION/NOTICE.md"       "$DEST/NOTICE-qpdf.md"
cp "$ROOT/Vendor/mozjpeg/LICENSE-mozjpeg.md" "$DEST/LICENSE-libjpeg-mozjpeg.md"
cp "$ZOPFLI_SRC/COPYING"                 "$DEST/LICENSE-zopfli.txt"

codesign --force --sign - "$DEST/qpdf"

# --- Epic Phase 4+5: libqpdf als statische Universal-Library + C-Bridge ------
echo "→ Baue pdfcore (C-Bridge über libqpdf) …"
CORE_SRC="$(cd "$(dirname "$0")/.." && pwd)/Vendor/pdfcore/src"
CORE_DEST="$(cd "$(dirname "$0")/.." && pwd)/Vendor/pdfcore"
mkdir -p "$CORE_DEST/lib" "$CORE_DEST/include/pdfcore"

# Header: öffentliche qpdf-Header + generierte Configs
mkdir -p "$WORK/qpdf-headers/qpdf"
cp "$WORK/qpdf-$VERSION"/include/qpdf/*.h "$WORK/qpdf-$VERSION"/include/qpdf/*.hh \
   "$WORK/qpdf-headers/qpdf/" 2>/dev/null || true
find "$WORK/qpdf-build" -name "qpdf-config.h" -o -name "QPDFVersion.h" | while read -r f; do
    cp "$f" "$WORK/qpdf-headers/qpdf/"
done

# Use the same bridge build as incremental rebuilds so the full codec and
# font dependencies are included in both paths.
"$ROOT/Scripts/build-pdfcore.sh"
cat > "$CORE_DEST/include/module.modulemap" <<'MOD'
module pdfcore {
    header "pdfcore/pdfcore.h"
    export *
}
MOD

echo
echo "✓ Vendored: $DEST"
ls -la "$DEST"
"$DEST/qpdf" --version
