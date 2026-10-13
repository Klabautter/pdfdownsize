#!/bin/bash
# Vendored HarfBuzz (hb-subset) für PDFTools erzeugen (Roadmap Phase 5b:
# Font-Subsetting).
#
# Ergebnis: EINE universelle (arm64 + x86_64) STATISCHE libharfbuzz.a in
# Vendor/harfbuzz – Muster von vendor-libtiff.sh (nur System-Abhängigkeiten,
# keine Dylibs, kein Homebrew auf dem Zielrechner).
#
#   Vendor/harfbuzz/include/hb/  öffentliche Header (hb*.h inkl. hb-subset.h)
#   Vendor/harfbuzz/lib/         libharfbuzz.a (fett: arm64 + x86_64)
#   Vendor/harfbuzz/             NOTICE-harfbuzz.md
#
# Build-Konfiguration (Ziel: Subsetter + OT/TTF-Tabellen-IO, sonst nichts):
#   - HB_BUILD_SUBSET=ON        → Subsetter (hb_subset_*) wird mitgebaut
#   - alle externen Integrations-Backends explizit OFF: glib, icu, cairo,
#     freetype, graphite2, gobject, introspection, CoreText (Unicode kommt
#     aus der eingebauten UCD-Implementierung hb-ucd)
#   - BUILD_SHARED_LIBS=0       → nur statische Archive
#   - Utils/Tests/Docs aus      → hermetischer Build
#   - Shaping-Maschinerie bleibt im Archiv (CMake hat keinen Schalter);
#     die Subsetter-Pfade nutzen sie nicht, sie kostet nur Archivgröße.
#
# API-Generation (dokumentiert): HarfBuzz 11.5.1 – die seit 2.9/5.x stabile
# SETS-API: hb_subset_input_create_or_fail, hb_subset_input_unicode_set,
# hb_subset_input_glyph_set, hb_subset_input_set_flags, hb_subset_or_fail.
#
# Achtung Merged-Archiv: harfbuzz.cc (Amalgam) und die Subset-Quellen
# kompilieren BEIDE hb-static.cc – vor dem Zusammenführen mit libtool wird
# das Dublett-Objekt aus dem Subset-Archiv entfernt, sonst würde der
# App-Link mit doppelten Symbolen (_hb_…) scheitern.
#
# Aufruf:            ./Scripts/vendor-harfbuzz.sh [--force]
# Standard-Version:  11.5.1 (Github-Releases, Aug 2026 ermittelt)

set -euo pipefail

VERSION="11.5.1"
WORK="/tmp/opencode/pdftools-vendor"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Vendor/harfbuzz"
CM="$WORK/cmake-app/CMake.app/Contents/bin/cmake"
ARCHS="arm64;x86_64"
SRC="$WORK/harfbuzz-$VERSION"

# --- Argumente: --force erzwingt Neubau ---------------------------------------
FORCE=0
for ARG in "$@"; do
    case "$ARG" in
        --force) FORCE=1 ;;
        *) echo "Unbekanntes Argument: $ARG (erlaubt: --force)" >&2; exit 1 ;;
    esac
done

if [ "$FORCE" -eq 0 ] && [ -f "$DEST/lib/libharfbuzz.a" ]; then
    echo "✓ Vendor/harfbuzz existiert bereits – Skip (Neubau mit --force)."
    lipo -info "$DEST/lib/libharfbuzz.a"
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
    echo "→ Lade HarfBuzz $VERSION …"
    curl -sL --max-time 600 -o "$WORK/harfbuzz-src.tar.xz" \
        "https://github.com/harfbuzz/harfbuzz/releases/download/$VERSION/harfbuzz-$VERSION.tar.xz"
    tar xJf "$WORK/harfbuzz-src.tar.xz" -C "$WORK"
fi

# --- HarfBuzz: pro Architektur statisch bauen, dann .a mergen -------------------
echo "→ Baue HarfBuzz $VERSION (arm64 + x86_64, statisch, Subsetter an, kein glib/icu/cairo) …"
for ARCH in arm64 x86_64; do
    if [ "$FORCE" -eq 1 ] || [ ! -f "$WORK/harfbuzz-$ARCH/libharfbuzz.a" ]; then
        "$CM" -S "$SRC" -B "$WORK/harfbuzz-$ARCH" \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_OSX_ARCHITECTURES=$ARCH \
            -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0 \
            -DBUILD_SHARED_LIBS=OFF \
            -DHB_BUILD_SUBSET=ON \
            -DHB_HAVE_GLIB=OFF -DHB_HAVE_ICU=OFF -DHB_HAVE_CAIRO=OFF \
            -DHB_HAVE_FREETYPE=OFF -DHB_HAVE_GRAPHITE2=OFF \
            -DHB_HAVE_GOBJECT=OFF -DHB_HAVE_INTROSPECTION=OFF \
            -DHB_HAVE_CORETEXT=OFF \
            -DHB_BUILD_UTILS=OFF > /dev/null
        "$CM" --build "$WORK/harfbuzz-$ARCH" --parallel > /dev/null
    fi
done

# --- Dubletten bereinigen und universelles Archiv bauen -------------------------
# hb-static.cc liegt in BEIDEN Archiven (siehe Kopf-Kommentar). Aus dem
# Subset-Archiv wird das Objekt entfernt, bevor libtool fasst.
HB_STATIC_MEMBER=$("$CM" -E echo "x" >/dev/null 2>&1; ar t "$WORK/harfbuzz-arm64/libharfbuzz-subset.a" | grep "hb-static" | head -1)
if [ -n "$HB_STATIC_MEMBER" ]; then
    for ARCH in arm64 x86_64; do
        ar d "$WORK/harfbuzz-$ARCH/libharfbuzz-subset.a" "$HB_STATIC_MEMBER"
        ranlib "$WORK/harfbuzz-$ARCH/libharfbuzz-subset.a"
    done
fi

mkdir -p "$WORK/harfbuzz-universal/lib"
libtool -static -o "$WORK/harfbuzz-universal/lib/libharfbuzz.a" \
    "$WORK/harfbuzz-arm64/libharfbuzz.a" \
    "$WORK/harfbuzz-arm64/libharfbuzz-subset.a" \
    "$WORK/harfbuzz-x86_64/libharfbuzz.a" \
    "$WORK/harfbuzz-x86_64/libharfbuzz-subset.a"

# --- Verifikation direkt im Build-Verzeichnis -----------------------------------
echo "→ Verifikation (lipo/nm) …"
lipo -info "$WORK/harfbuzz-universal/lib/libharfbuzz.a"
# Sets-API der dokumentierten Generation muss vollständig da sein.
nm -gU "$WORK/harfbuzz-universal/lib/libharfbuzz.a" \
    | grep -E "_hb_subset_input_create_or_fail|_hb_subset_or_fail|_hb_subset_input_unicode_set|_hb_subset_input_glyph_set|_hb_subset_input_set_flags|_hb_set_create|_hb_set_add_range" | sort -u

# --- Nach Vendor ---------------------------------------------------------------
rm -rf "$DEST"
mkdir -p "$DEST/include/hb" "$DEST/lib"
cp "$WORK/harfbuzz-universal/lib/libharfbuzz.a" "$DEST/lib/libharfbuzz.a"

# Öffentliche Header: alle hb*.h aus src (architekturunabhängig).
cp "$SRC"/src/hb*.h "$DEST/include/hb/"

# NOTICE: HarfBuzz "Old MIT" (COPYING im Quellbaum).
{
    echo "# NOTICE – HarfBuzz (vendored)"
    echo
    echo "Dieses Verzeichnis enthält eine statische, universelle Build-Artefakt-Kopie"
    echo "(arm64 + x86_64) von **HarfBuzz v$VERSION** (Kern + Subsetter)."
    echo
    echo "- Quelle: https://github.com/harfbuzz/harfbuzz (Release \`$VERSION\`,"
    echo "  Tarball harfbuzz-$VERSION.tar.xz)"
    echo "- Lizenz: „Old MIT“ (upstream \`COPYING\`); einzelne Teile tragen"
    echo "  eigene Lizenzhinweise in Unterverzeichnissen (z. B. src/hb-ucd)."
    echo "- Verwendung: Font-Subsetting über die hb-subset-Sets-API"
    echo "  (hb_subset_input_create_or_fail / hb_subset_input_unicode_set /"
    echo "  hb_subset_input_glyph_set / hb_subset_input_set_flags /"
    echo "  hb_subset_or_fail) für COMPRESSION_ROADMAP.md, Phase 5b."
    echo "  Keine Änderungen am Quellcode."
    echo "- Build-Konfiguration: Release, CMake, BUILD_SHARED_LIBS=OFF,"
    echo "  HB_BUILD_SUBSET=ON; glib/icu/cairo/freetype/graphite2/gobject/"
    echo "  introspection/CoreText OFF (Unicode via eingebauter hb-ucd),"
    echo "  Utils/Tests/Docs ohne Inhalt. Deployment-Target macOS 11.0."
    echo "- Archivzusammenführung: hb-static.cc (Dublette zwischen Kern und"
    echo "  Subset-Target) ist aus dem Subset-Anteil entfernt."
    echo
    echo "Original-Lizenztext:"
    echo
    cat "$SRC/COPYING"
} > "$DEST/NOTICE-harfbuzz.md"

# --- Abschluss ------------------------------------------------------------------
echo
echo "✓ Vendored: $DEST"
ls -la "$DEST" "$DEST/lib"
ls "$DEST/include/hb" | head -5
lipo -info "$DEST/lib/libharfbuzz.a"
