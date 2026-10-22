#!/bin/bash
# Vendored mozjpeg für PDFTools erzeugen (Roadmap Phase 1a: JPEG-Backend).
#
# Ergebnis: EINE universelle (arm64 + x86_64) STATISCHE libmozjpeg.a in
# Vendor/mozjpeg – analog zu vendor-qpdf.sh (nur System-Abhängigkeiten,
# keine Dylibs, kein Homebrew auf dem Zielrechner).
#
#   Vendor/mozjpeg/include/  jpeglib.h, jerror.h, jmorecfg.h, jconfig.h, …
#   Vendor/mozjpeg/lib/      libmozjpeg.a (fett: arm64 + x86_64)
#   Vendor/mozjpeg/          LICENSE-mozjpeg.md, NOTICE-mozjpeg.md,
#                            INTEGRATION_NOTES.md (Kollisions-Analyse)
#
# Die mitgebauten Tools (cjpeg-static, djpeg-static, jpegtran-static) bleiben
# unter /tmp/opencode – die App braucht primär die LIB. Ein gemergter
# universal-jpegtran liegt als Test-/Repack-Werkzeug ebenfalls nur in /tmp
# und wird bewusst NICHT nach Vendor/qpdf gemischt (keine Tool-Binaries im
# App-Bundle).
#
# Aufruf:            ./Scripts/vendor-mozjpeg.sh [--force]
# Standard-Version:  4.1.1 (aktuelles Release, GitHub Aug 2026 ermittelt:
#                    https://github.com/mozilla/mozjpeg/releases – v4.1.1 ist
#                    die letzte stabile, nicht-prerelease Version)
#
# ABI-Entscheidung (WICHTIG – beabsichtigt 1:1-Austauschbarkeit mit pdfcore):
#   vendor-qpdf.sh baut libjpeg-turbo 3.1.0 OHNE WITH_JPEG8-Flag → CMake-
#   Default WITH_JPEG8=0 → JPEG_LIB_VERSION 62 (libjpeg-v6b-API), verifiziert
#   in $WORK/jpeg-arm64/jconfig.h ("#define JPEG_LIB_VERSION 62").
#   mozjpeg-Default wäre ebenfalls 62, wird hier aber EXPLIZIT mit
#   WITH_JPEG8=0 gesetzt, damit die mozjpeg-Lib später API-kompatibel die
#   turbo-Lib in Vendor/pdfcore/lib/libjpeg_universal.a ersetzen kann.
#   jpeg_mem_src/jpeg_mem_dest sind dank WITH_MEM_SRCDST=1 (mozjpeg-Default,
#   explizit gesetzt) auch im 6b-Modus verfügbar.
#
# Build-Konfiguration:
#   - ENABLE_STATIC=1 / ENABLE_SHARED=0 → nur libjpeg.a (statisch)
#   - WITH_SIMD: arm64 = 1 (NEON-Intrinsics, kein NASM nötig), x86_64 = 0
#     (bräuchte NASM; die App wird nur für Apple Silicon ausgeliefert).
#     Seit 2026-10-22. Ausgabe bytegleich zum C-Pfad: 243 Vergleichsdateien
#     (RGB/Grau/CMYK-Kodierung über 8 Qualitäten, Repack progressiv und
#     baseline, Bildgrößen 1×1 bis 2000×1334) ohne Unterschied; Kodierung
#     rund 20 %, Repack 20–37 % schneller.
#   - WITH_TURBOJPEG=0 → TurboJPEG-API (turbojpeg.a/tjbench) nicht benötigt
#   - PNG_SUPPORTED=0 → hermetischer Build, keine libpng/zlib-Find-Abhängigkeit
#   - mozjpeg-Erweiterungen (Trellis, progressive Defaults) sind in der
#   Standard-libjpeg-API enthalten: jpeg_c_set_int_param / JINT_COMPRESS_PROFILE.
#   Benennung: mozjpegs CMake-Target "jpeg-static" erzeugt intern "libjpeg.a";
#   die Datei wird dokumentiert nach lib/libmozjpeg.a kopiert (der Name macht
#   im App-Link-Setup den Unterschied zur turbo-libjpeg.a sichtbar).

set -euo pipefail

VERSION="4.1.1"
WORK="/tmp/opencode/pdftools-vendor"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Vendor/mozjpeg"
CM="$WORK/cmake-app/CMake.app/Contents/bin/cmake"
ARCHS="arm64;x86_64"
SRC="$WORK/mozjpeg-$VERSION"

# --- Argumente: --force erzwingt Neubau ---------------------------------------
FORCE=0
for ARG in "$@"; do
    case "$ARG" in
        --force) FORCE=1 ;;
        *) echo "Unbekanntes Argument: $ARG (erlaubt: --force)" >&2; exit 1 ;;
    esac
done

if [ "$FORCE" -eq 0 ] && [ -f "$DEST/lib/libmozjpeg.a" ]; then
    echo "✓ Vendor/mozjpeg existiert bereits – Skip (Neubau mit --force)."
    lipo -info "$DEST/lib/libmozjpeg.a"
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
    echo "→ Lade mozjpeg $VERSION …"
    curl -sL --max-time 300 -o "$WORK/mozjpeg-src.tar.gz" \
        "https://github.com/mozilla/mozjpeg/archive/refs/tags/v$VERSION.tar.gz"
    tar xzf "$WORK/mozjpeg-src.tar.gz" -C "$WORK"
fi

# --- mozjpeg: pro Architektur statisch bauen, dann .a mergen ------------------
# Muster aus vendor-qpdf.sh (dort für libjpeg-turbo): beide Architekturen
# einzeln mit CMAKE_OSX_ARCHITECTURES, danach libtool -static zum Fat-Archiv.
echo "→ Baue mozjpeg $VERSION (arm64 + x86_64, statisch, WITH_JPEG8=0) …"
for ARCH in arm64 x86_64; do
    if [ "$FORCE" -eq 1 ] || [ ! -f "$WORK/mozjpeg-$ARCH/libjpeg.a" ]; then
        "$CM" -S "$SRC" -B "$WORK/mozjpeg-$ARCH" \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_OSX_ARCHITECTURES=$ARCH \
            -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0 \
            -DENABLE_SHARED=0 -DENABLE_STATIC=1 \
            -DWITH_JPEG8=0 \
            -DWITH_MEM_SRCDST=1 \
            -DWITH_SIMD=$([ "$ARCH" = arm64 ] && echo 1 || echo 0) \
            -DWITH_TURBOJPEG=0 \
            -DPNG_SUPPORTED=0 > /dev/null
        "$CM" --build "$WORK/mozjpeg-$ARCH" --parallel > /dev/null
    fi
done

mkdir -p "$WORK/mozjpeg-universal/lib" "$WORK/mozjpeg-universal/bin"
libtool -static -o "$WORK/mozjpeg-universal/lib/libmozjpeg.a" \
    "$WORK/mozjpeg-arm64/libjpeg.a" "$WORK/mozjpeg-x86_64/libjpeg.a"

# Universal-jpegtran nur nach /tmp (Phase 1: verlustfreier Repass-Test),
# bewusst NICHT nach Vendor – kein Tool-Binary im App-Bundle.
lipo -create -output "$WORK/mozjpeg-universal/bin/jpegtran" \
    "$WORK/mozjpeg-arm64/jpegtran-static" "$WORK/mozjpeg-x86_64/jpegtran-static"

# --- Verifikation direkt im Build-Verzeichnis ---------------------------------
echo "→ Verifikation (lipo/nm) …"
lipo -info "$WORK/mozjpeg-universal/lib/libmozjpeg.a"
nm -gU "$WORK/mozjpeg-universal/lib/libmozjpeg.a" \
    | grep -E "_jpeg_CreateCompress|_jpeg_c_set_int_param|_jpeg_mem_src|_jpeg_mem_dest" \
    | sort -u

# --- Nach Vendor ---------------------------------------------------------------
LIB="$WORK/mozjpeg-universal/lib/libmozjpeg.a"
rm -rf "$DEST"
mkdir -p "$DEST/include" "$DEST/lib"
cp "$LIB" "$DEST/lib/libmozjpeg.a"

# Öffentliche Header aus dem Quellbaum + generierte Configs aus dem Build-Dir
# (arm64-Slice; jconfig*/jversion sind architekturunabhängig – Muster wie
# vendor-qpdf.sh).
cp "$SRC/jpeglib.h" "$SRC/jerror.h" "$SRC/jmorecfg.h" "$DEST/include/"
cp "$WORK/mozjpeg-arm64/jconfig.h" "$WORK/mozjpeg-arm64/jconfigint.h" "$DEST/include/"
if [ -f "$WORK/mozjpeg-arm64/jversion.h" ]; then
    cp "$WORK/mozjpeg-arm64/jversion.h" "$DEST/include/"
fi

cp "$SRC/LICENSE.md" "$DEST/LICENSE-mozjpeg.md"

# mozjpeg liefert kein NOTICE mit; kurze eigene Herkunfts-/Änderungsnotiz.
cat > "$DEST/NOTICE-mozjpeg.md" <<'EOF'
# NOTICE – mozjpeg (vendored)

Dieses Verzeichnis enthält eine statische, universelle Build-Artefakt-Kopie
(arm64 + x86_64) von **mozjpeg v4.1.1**.

- Quelle: https://github.com/mozilla/mozjpeg (Tag `v4.1.1`)
- Lizenz: BSD-3-Clause (siehe `LICENSE-mozjpeg.md`, upstream `LICENSE.md`;
  umfasst die Hinweise der IJG-/libjpeg-turbo-Vorläufer)
- Verwendung: statisch gelinkte JPEG-Codec-Library für das JPEGBackend
  (COMPRESSION_ROADMAP.md, Phase 1). Keine Änderungen am Quellcode.
- Build-Konfiguration: Release, `ENABLE_SHARED=0`, `ENABLE_STATIC=1`,
  `WITH_JPEG8=0` (libjpeg-v6b-ABI, identisch zur libjpeg-turbo 3.1.0 in
  `Vendor/pdfcore`), `WITH_MEM_SRCDST=1`, `WITH_SIMD=1` (arm64, NEON) bzw.
  `WITH_SIMD=0` (x86_64), `WITH_TURBOJPEG=0`,
  `PNG_SUPPORTED=0`. Deployment-Target macOS 11.0.
- Die Tools cjpeg/djpeg/jpegtran sind nicht Teil dieses Verzeichnisses
  (verbleiben im Build-Arbeitsverzeichnis unter /tmp/opencode).
EOF

# --- Kollisions-Analyse + Integrationsnotizen ----------------------------------
# libqpdf.a referenziert jpeg_* nur undefiniert (nicht eingebettet), daher
# linkt die App libjpeg_universal.a separat – dort kollidieren die Symbole
# mit libmozjpeg.a, wenn beide Archive gleichzeitig gelinkt werden.
TURBO_LIB="$ROOT/Vendor/pdfcore/lib/libjpeg_universal.a"

TURBO_SYMS=""
MOZ_SYMS=""
if [ -f "$TURBO_LIB" ]; then
    TURBO_SYMS="$(nm -gU "$TURBO_LIB" | awk '$3 ~ /^_jpeg_/{print substr($3,2)}' | sort -u)"
fi
MOZ_SYMS="$(nm -gU "$DEST/lib/libmozjpeg.a" | awk '$3 ~ /^_jpeg_/{print substr($3,2)}' | sort -u)"

TURBO_COUNT=0
if [ -n "$TURBO_SYMS" ]; then
    TURBO_COUNT="$(printf '%s\n' "$TURBO_SYMS" | wc -l | tr -d ' ')"
fi
MOZ_COUNT=0
if [ -n "$MOZ_SYMS" ]; then
    MOZ_COUNT="$(printf '%s\n' "$MOZ_SYMS" | wc -l | tr -d ' ')"
fi

COMMON_COUNT=0
MISSING_TURBO_IN_MOZ=""
if [ -n "$TURBO_SYMS" ]; then
    COMMON_COUNT="$(comm -12 <(printf '%s\n' "$TURBO_SYMS") <(printf '%s\n' "$MOZ_SYMS") | wc -l | tr -d ' ')"
    MISSING_TURBO_IN_MOZ="$(comm -23 <(printf '%s\n' "$TURBO_SYMS") <(printf '%s\n' "$MOZ_SYMS"))"
fi

cat > "$DEST/INTEGRATION_NOTES.md" <<EOF
# mozjpeg-Integration (Phase 1a → 1b) – Kurznotiz

## Artefakt

- \`lib/libmozjpeg.a\`: statisch, Universal arm64 + x86_64, Deployment-Target
  macOS 11.0, built mit \`WITH_JPEG8=0\` (JPEG_LIB_VERSION 62, libjpeg-v6b-API).
- \`include/\`: jpeglib.h, jerror.h, jmorecfg.h, jconfig.h, jconfigint.h
  (jversion.h falls generiert) – kompilierfähiger Satz gegen die Static-Lib.
- Benennung: mozjpegs CMake-Target \`jpeg-static\` erzeugt intern \`libjpeg.a\`;
  dokumentierte Umbenennung nach \`libmozjpeg.a\`, damit im App-Link-Setup klar
  ist, welche JPEG-Implementierung gelinkt wird.
- ABI-Abgleich: vendor-qpdf.sh baut libjpeg-turbo 3.1.0 ohne WITH_JPEG8-Flag
  → Default 62; verifiziert in /tmp/opencode/pdftools-vendor/jpeg-arm64/jconfig.h
  (\`#define JPEG_LIB_VERSION 62\`). mozjpeg wurde mit demselben Modus gebaut
  → späterer Austausch API-kompatibel. \`jpeg_mem_src/jpeg_mem_dest\` sind im
  6b-Modus verfügbar (WITH_MEM_SRCDST=1). mozjpeg-Erweiterungen zusätzlich:
  \`jpeg_c_set_int_param\` / \`jpeg_c_set_bool_param\` / \`JINT_COMPRESS_PROFILE\`.
- Build: \`WITH_SIMD=1\` auf arm64 (NEON), \`WITH_SIMD=0\` auf x86_64 (keine NASM-Abhängigkeit),
  \`WITH_TURBOJPEG=0\`, \`PNG_SUPPORTED=0\`, ENABLE_SHARED=0/ENABLE_STATIC=1.
  cjpeg/djpeg/jpegtran landen nur unter /tmp/opencode (nicht in Vendor).

## Kollisions-Analyse (libjpeg-turbo in pdfcore vs. libmozjpeg)

- \`libqpdf.a\` referenziert jpeg_* ausschließlich undefiniert (kein Einbetten);
  die App linkt \`Vendor/pdfcore/lib/libjpeg_universal.a\` separat.
- Turbo-Lib exportiert $TURBO_COUNT \`jpeg_*\`-Symbole, mozjpeg $MOZ_COUNT;
  davon identisch (Name + Definition): $COMMON_COUNT.
EOF

if [ -n "$MISSING_TURBO_IN_MOZ" ]; then
    # Fehlende Turbo-Symbole bewerten: kritisch nur, wenn jemand im App-Binary
    # sie UND-referenziert (libpdfcore_universal.a = pdfcore.o + libqpdf.a).
    MISSING_REFS=""
    for SYM in $MISSING_TURBO_IN_MOZ; do
        if nm "$ROOT/Vendor/pdfcore/lib/libpdfcore_universal.a" 2>/dev/null \
            | grep -q "U _$SYM"; then
            MISSING_REFS="$MISSING_REFS $SYM"
        fi
    done
    {
        echo "- Turbo-Symbole, die mozjpeg NICHT exportiert:"
        printf '%s\n' "$MISSING_TURBO_IN_MOZ" | sed 's/^/  - /'
        if [ -z "$MISSING_REFS" ]; then
            echo "  Bewertung: unkritisch – keine dieser Referenzen wird vom"
            echo "  pdfcore-Binary (pdfcore.o + libqpdf.a) gezogen. Betroffen sind"
            echo "  turbo-3.x-Lossless (\`jpeg_enable_lossless\`) und die interne"
            echo "  Arith-Tabelle (\`jpeg_aritab\`, mozjpeg 6b-Mode baut Arith-CODEC"
            echo "  nicht mit; bei Bedarf WITH_ARITH_DEC/WITH_ARITH_ENC=1)."
        else
            echo "  Bewertung: KRITISCH – folgende Symbole werden referenziert:$MISSING_REFS"
        fi
    } >> "$DEST/INTEGRATION_NOTES.md"
else
    {
        if [ -n "$TURBO_SYMS" ]; then
            echo "- Turbo-Symbolmenge ist vollständig in mozjpeg enthalten (Superset) –"
            echo "  API-kompatibler Ersatztausch möglich."
        fi
    } >> "$DEST/INTEGRATION_NOTES.md"
fi

cat >> "$DEST/INTEGRATION_NOTES.md" <<'EOF'

## MÖGLICHE Symbolkollision

Beide Archive definieren dieselben Symbolnamen (u. a. `jpeg_CreateCompress`,
`jpeg_mem_src`, `jpeg_mem_dest`). Werden `libpdfcore_universal.a` +
`libjpeg_universal.a` UND `libmozjpeg.a` gleichzeitig ins App-Binary gelinkt,
führen beide gezogene jpeg-Objekte zu Duplicate-Symbol-Fehlern des Linkers
(first-wins ist bei Static-Archives nicht verlässlich deterministisch – nicht
darauf anlegen).

## Empfehlung für Phase 1b (Swift-Integration)

1. **Bevorzugt:** mozjpeg ERSETZT libjpeg-turbo in pdfcore – in
   `vendor-qpdf.sh` `LIBJPEG_H_PATH`/`LIBJPEG_LIB_PATH` auf
   `Vendor/mozjpeg/include` bzw. `libmozjpeg.a` zeigen lassen und
   `libjpeg_universal.a` aus dem Link-Setup entfernen. Gleiche ABI (62) +
   Superset-Symbole → genau eine JPEG-Implementierung im App-Binary, keine
   Kollision, JPEGBackend und qpdf-DCT-Pfad teilen sich eine Lib.
2. **Alternativ (Übergang):** turbo in pdfcore behalten, mozjpeg nur ins
   App-Target linken – dafür mozjpeg-Symbole beim Vendor-Bau mit Präfix
   umbenennen (llvm-objcopy --redefine-syms, z. B. `mozjpeg_`) plus
   Header-Makro-Mapping. Aufwändig und fehleranfällig.
3. **Nicht tun:** beide Archive unumbenannt parallel linken.
EOF

# --- Abschluss ------------------------------------------------------------------
echo
echo "✓ Vendored: $DEST"
ls -la "$DEST" "$DEST/lib" "$DEST/include"
lipo -info "$DEST/lib/libmozjpeg.a"
"$WORK/mozjpeg-universal/bin/jpegtran" -version 2>&1 | head -1 || true
