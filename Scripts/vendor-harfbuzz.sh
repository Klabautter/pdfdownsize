#!/bin/bash
# Vendored HarfBuzz (hb-subset) für PDFdownsize erzeugen (Font-Subsetting).
#
# Ergebnis: statische libharfbuzz.a (nur arm64, Kern + Subsetter in EINEM
# Archiv) in Vendor/harfbuzz:
#
#   Vendor/harfbuzz/include/hb/  öffentliche Header (hb*.h inkl. hb-subset.h)
#   Vendor/harfbuzz/lib/         libharfbuzz.a
#   Vendor/harfbuzz/             NOTICE-harfbuzz.md
#
# Aufruf:  ./Scripts/vendor-harfbuzz.sh [--force]
#
# Build-Konfiguration: HB_BUILD_SUBSET=ON; glib, icu, cairo, freetype,
# graphite2, gobject, introspection, CoreText aus (Unicode aus hb-ucd);
# Utils aus. Benutzte API: hb_subset_input_create_or_fail,
# hb_subset_input_unicode_set, hb_subset_input_glyph_set,
# hb_subset_input_set_flags, hb_subset_or_fail.
#
# Kern (harfbuzz.cc) und Subsetter kompilieren BEIDE hb-static.cc. Vor dem
# Zusammenführen wird das Dublett aus dem Subset-Archiv entfernt, sonst
# scheitert der App-Link an doppelten Symbolen.

set -euo pipefail
source "$(dirname "$0")/vendor-common.sh"
parse_force "$@"

VERSION="11.5.1"
DEST="$VENDOR_ROOT/Vendor/harfbuzz"
SRC="$WORK/harfbuzz-$VERSION"
BUILD="$WORK/harfbuzz-$VENDOR_ARCH"

if [ "$FORCE" -eq 0 ] && [ -f "$DEST/lib/libharfbuzz.a" ]; then
    echo "✓ Vendor/harfbuzz existiert bereits – Skip (Neubau mit --force)."
    require_arm64_only "$DEST/lib/libharfbuzz.a"
    exit 0
fi

ensure_cmake
fetch_verified "harfbuzz-$VERSION.tar.xz" "$SRC"

echo "→ Baue HarfBuzz $VERSION ($VENDOR_ARCH, statisch, Subsetter an) …"
rm -rf "$BUILD"
"$CM" -S "$SRC" -B "$BUILD" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES="$VENDOR_ARCH" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$VENDOR_DEPLOYMENT_TARGET" \
    -DBUILD_SHARED_LIBS=OFF \
    -DHB_BUILD_SUBSET=ON \
    -DHB_HAVE_GLIB=OFF -DHB_HAVE_ICU=OFF -DHB_HAVE_CAIRO=OFF \
    -DHB_HAVE_FREETYPE=OFF -DHB_HAVE_GRAPHITE2=OFF \
    -DHB_HAVE_GOBJECT=OFF -DHB_HAVE_INTROSPECTION=OFF \
    -DHB_HAVE_CORETEXT=OFF \
    -DHB_BUILD_UTILS=OFF > /dev/null
"$CM" --build "$BUILD" --parallel > /dev/null

HB_STATIC_MEMBER=$(ar t "$BUILD/libharfbuzz-subset.a" | grep "hb-static" | head -1 || true)
if [ -n "$HB_STATIC_MEMBER" ]; then
    echo "→ Entferne Dublett $HB_STATIC_MEMBER aus dem Subset-Archiv …"
    ar d "$BUILD/libharfbuzz-subset.a" "$HB_STATIC_MEMBER"
    ranlib "$BUILD/libharfbuzz-subset.a"
fi

MERGED="$BUILD/libharfbuzz-merged.a"
libtool -static -o "$MERGED" "$BUILD/libharfbuzz.a" "$BUILD/libharfbuzz-subset.a"

echo "→ Verifikation (lipo/nm) …"
require_arm64_only "$MERGED"
nm -gU "$MERGED" \
    | grep -E "_hb_subset_input_create_or_fail|_hb_subset_or_fail|_hb_subset_input_unicode_set|_hb_subset_input_glyph_set|_hb_subset_input_set_flags|_hb_set_create|_hb_set_add_range" | sort -u

rm -rf "$DEST"
mkdir -p "$DEST/include/hb" "$DEST/lib"
cp "$MERGED" "$DEST/lib/libharfbuzz.a"
cp "$SRC"/src/hb*.h "$DEST/include/hb/"

{
    echo "# NOTICE – HarfBuzz (vendored)"
    echo
    echo "Dieses Verzeichnis enthält eine statische Build-Artefakt-Kopie (nur arm64)"
    echo "von **HarfBuzz v$VERSION** (Kern + Subsetter)."
    echo
    echo "- Quelle: https://github.com/harfbuzz/harfbuzz (Release \`$VERSION\`,"
    echo "  Tarball harfbuzz-$VERSION.tar.xz, per SHA-256 geprüft)"
    echo "- Lizenz: „Old MIT“ (upstream \`COPYING\`); einzelne Teile tragen"
    echo "  eigene Lizenzhinweise in Unterverzeichnissen (z. B. src/hb-ucd)."
    echo "- Verwendung: Font-Subsetting über die hb-subset-Sets-API"
    echo "  (hb_subset_input_create_or_fail / hb_subset_input_unicode_set /"
    echo "  hb_subset_input_glyph_set / hb_subset_input_set_flags /"
    echo "  hb_subset_or_fail). Keine Änderungen am Quellcode."
    echo "- Build-Konfiguration: Release, CMake, BUILD_SHARED_LIBS=OFF,"
    echo "  HB_BUILD_SUBSET=ON; glib/icu/cairo/freetype/graphite2/gobject/"
    echo "  introspection/CoreText OFF (Unicode via eingebauter hb-ucd),"
    echo "  Utils/Tests/Docs ohne Inhalt. Deployment-Target macOS $VENDOR_DEPLOYMENT_TARGET."
    echo "- Archivzusammenführung: hb-static.cc (Dublette zwischen Kern und"
    echo "  Subset-Target) ist aus dem Subset-Anteil entfernt."
    echo
    echo "Original-Lizenztext:"
    echo
    cat "$SRC/COPYING"
} > "$DEST/NOTICE-harfbuzz.md"

echo
echo "✓ Vendored: $DEST"
require_arm64_only "$DEST/lib/libharfbuzz.a"
