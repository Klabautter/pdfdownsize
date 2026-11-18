#!/bin/bash
# Vendored mozjpeg für PDFdownsize erzeugen (JPEG-Codec).
#
# Ergebnis: statische libmozjpeg.a (nur arm64) in Vendor/mozjpeg.
#
#   Vendor/mozjpeg/include/  jpeglib.h, jerror.h, jmorecfg.h, jconfig.h, …
#   Vendor/mozjpeg/lib/      libmozjpeg.a
#   Vendor/mozjpeg/          LICENSE-mozjpeg.md, NOTICE-mozjpeg.md
#
# build-pdfcore.sh backt die Bibliothek in libpdfcore.a ein – qpdf (DCT-Pfad)
# und das JPEGBackend teilen sich damit genau eine JPEG-Implementierung.
#
# Aufruf:  ./Scripts/vendor-mozjpeg.sh [--force]
#
# Build-Konfiguration:
#   - WITH_JPEG8=0 → JPEG_LIB_VERSION 62 (libjpeg-v6b-API), wie qpdf sie erwartet
#   - WITH_MEM_SRCDST=1 → jpeg_mem_src/jpeg_mem_dest auch im 6b-Modus
#   - WITH_SIMD=1 (NEON, kein NASM nötig). Seit 22.10.2026; Ausgabe bytegleich
#     zum C-Pfad über 243 Vergleichsdateien, Kodierung rund 20 % schneller.
#   - WITH_TURBOJPEG=0, PNG_SUPPORTED=0 → hermetisch
#   - mozjpeg-Erweiterungen (Trellis, Profile) über jpeg_c_set_int_param.
#   mozjpegs Target "jpeg-static" erzeugt libjpeg.a; die Kopie heißt
#   libmozjpeg.a, damit im Link klar ist, welche Implementierung drin ist.

set -euo pipefail
source "$(dirname "$0")/vendor-common.sh"
parse_force "$@"

VERSION="4.1.1"
DEST="$VENDOR_ROOT/Vendor/mozjpeg"
SRC="$WORK/mozjpeg-$VERSION"
BUILD="$WORK/mozjpeg-$VENDOR_ARCH"

if [ "$FORCE" -eq 0 ] && [ -f "$DEST/lib/libmozjpeg.a" ]; then
    echo "✓ Vendor/mozjpeg existiert bereits – Skip (Neubau mit --force)."
    require_arm64_only "$DEST/lib/libmozjpeg.a"
    exit 0
fi

ensure_cmake
fetch_verified "mozjpeg-$VERSION.tar.gz" "$SRC"

echo "→ Baue mozjpeg $VERSION ($VENDOR_ARCH, statisch, WITH_JPEG8=0) …"
rm -rf "$BUILD"
"$CM" -S "$SRC" -B "$BUILD" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES="$VENDOR_ARCH" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$VENDOR_DEPLOYMENT_TARGET" \
    -DENABLE_SHARED=0 -DENABLE_STATIC=1 \
    -DWITH_JPEG8=0 \
    -DWITH_MEM_SRCDST=1 \
    -DWITH_SIMD=1 \
    -DWITH_TURBOJPEG=0 \
    -DPNG_SUPPORTED=0 > /dev/null
"$CM" --build "$BUILD" --parallel > /dev/null

echo "→ Verifikation (lipo/nm) …"
require_arm64_only "$BUILD/libjpeg.a"
nm -gU "$BUILD/libjpeg.a" \
    | grep -E "_jpeg_CreateCompress|_jpeg_c_set_int_param|_jpeg_mem_src|_jpeg_mem_dest" \
    | sort -u

rm -rf "$DEST"
mkdir -p "$DEST/include" "$DEST/lib"
cp "$BUILD/libjpeg.a" "$DEST/lib/libmozjpeg.a"
cp "$SRC/jpeglib.h" "$SRC/jerror.h" "$SRC/jmorecfg.h" "$DEST/include/"
cp "$BUILD/jconfig.h" "$BUILD/jconfigint.h" "$DEST/include/"
[ -f "$BUILD/jversion.h" ] && cp "$BUILD/jversion.h" "$DEST/include/"
cp "$SRC/LICENSE.md" "$DEST/LICENSE-mozjpeg.md"

cat > "$DEST/NOTICE-mozjpeg.md" <<EOF
# NOTICE – mozjpeg (vendored)

Dieses Verzeichnis enthält eine statische Build-Artefakt-Kopie (nur arm64)
von **mozjpeg v$VERSION**.

- Quelle: https://github.com/mozilla/mozjpeg (Tag \`v$VERSION\`), Tarball per
  SHA-256 geprüft (Scripts/vendor-common.sh)
- Lizenz: BSD-3-Clause (siehe \`LICENSE-mozjpeg.md\`, upstream \`LICENSE.md\`;
  umfasst die Hinweise der IJG-/libjpeg-turbo-Vorläufer)
- Verwendung: statisch gelinkte JPEG-Codec-Library für das JPEGBackend und
  den DCT-Pfad von qpdf. Keine Änderungen am Quellcode.
- Build-Konfiguration: Release, \`ENABLE_SHARED=0\`, \`ENABLE_STATIC=1\`,
  \`WITH_JPEG8=0\` (libjpeg-v6b-ABI), \`WITH_MEM_SRCDST=1\`, \`WITH_SIMD=1\`
  (NEON), \`WITH_TURBOJPEG=0\`, \`PNG_SUPPORTED=0\`. Deployment-Target macOS
  $VENDOR_DEPLOYMENT_TARGET.
EOF

echo
echo "✓ Vendored: $DEST"
require_arm64_only "$DEST/lib/libmozjpeg.a"
