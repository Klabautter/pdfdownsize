#!/bin/bash
# Prüft, ob Vendor/pdfcore/lib/libpdfcore.a zum Quelltext passt (Masterplan G4).
#
#   1. Der eingebettete Quell-Hash (pdfcore_source_hash) entspricht
#      SHA-256(pdfcore.cc + pdfcore.h) des aktuellen Quelltexts.
#   2. Jede im Header deklarierte pdfcore_*-Funktion ist exportiert.
#   3. Die Bibliothek enthält nur arm64.
#   4. Der Header unter include/ ist identisch mit dem unter src/.
#
# Aufruf:  Scripts/verify-pdfcore.sh [--rebuild]
#   --rebuild  baut die Bridge vorher mit build-pdfcore.sh neu.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/Vendor/pdfcore/src"
LIB="$ROOT/Vendor/pdfcore/lib/libpdfcore.a"
fail=0

if [ "${1:-}" = "--rebuild" ]; then
    "$ROOT/Scripts/build-pdfcore.sh"
fi
[ -f "$LIB" ] || { echo "✗ $LIB fehlt – Scripts/build-pdfcore.sh ausführen"; exit 1; }

expected="$(cat "$SRC/pdfcore.cc" "$SRC/pdfcore.h" | shasum -a 256 | cut -d' ' -f1)"
if strings -a "$LIB" | grep -F "$expected" >/dev/null; then
    echo "✓ Quell-Hash ${expected:0:12} eingebettet"
else
    echo "✗ Bibliothek passt nicht zum Quelltext (erwartet ${expected:0:12}) – Scripts/build-pdfcore.sh"
    fail=1
fi

declared="$(grep -oE '\bpdfcore_[a-z0-9_]+\(' "$SRC/pdfcore.h" | tr -d '(' | sort -u)"
exported="$(nm -gU "$LIB" 2>/dev/null | awk '{print $3}' | grep -E '^_pdfcore_' | sed 's/^_//' | sort -u)"
missing="$(comm -23 <(printf '%s\n' "$declared") <(printf '%s\n' "$exported"))"
if [ -z "$missing" ]; then
    echo "✓ $(printf '%s\n' "$declared" | wc -l | tr -d ' ') deklarierte Funktionen exportiert"
else
    echo "✗ deklariert, aber nicht exportiert:"; printf '    %s\n' $missing
    fail=1
fi

archs="$(lipo -archs "$LIB")"
if [ "$archs" = "arm64" ]; then echo "✓ nur arm64"; else echo "✗ Architekturen: $archs"; fail=1; fi

if cmp -s "$SRC/pdfcore.h" "$ROOT/Vendor/pdfcore/include/pdfcore/pdfcore.h"; then
    echo "✓ Header unter include/ aktuell"
else
    echo "✗ include/pdfcore/pdfcore.h weicht von src/pdfcore.h ab"; fail=1
fi

exit $fail
