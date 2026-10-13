#!/bin/bash
# Release-Check für den gebündelten qpdf-Helper (Epic Phase 2).
# Schlägt fehl, wenn: Helper fehlt / nicht ausführbar / keine Universal-Binary /
# arm64 oder x86_64 fehlt / Lizenzdateien fehlen.
#
# Aufruf:  Scripts/release-check.sh [PFAD_ZU_APP]

set -uo pipefail

# Kein Befehl dieses Skripts liest von stdin – aber falls einer es doch tut
# (oder ein künftiger hinzukommt), darf er nicht auf eine Eingabe warten.
# Aus einem Test heraus gestartet erbt das Skript sonst das Terminal des
# Aufrufers und blockiert dort unbegrenzt.
exec < /dev/null

APP="${1:-}"
if [ -z "$APP" ]; then
    APP="$(ls -td ~/Library/Developer/Xcode/DerivedData/PDFTools-*/Build/Products/Release/PDFdownsize.app 2>/dev/null | head -1)"
fi
[ -n "$APP" ] || { echo "FEHLER: Keine App gefunden (Pfad als Argument übergeben)"; exit 1; }

QPDF="$APP/Contents/Helpers/qpdf"
fail=0

check() { # name, command...
    local name="$1"; shift
    if "$@" >/dev/null 2>&1; then
        echo "  ✓ $name"
    else
        echo "  ✗ $name"; fail=1
    fi
}

echo "Release-Check: $APP"
check "Helper vorhanden"          test -f "$QPDF"
check "Helper ausführbar"         test -x "$QPDF"
check "Universal Binary"          sh -c "lipo -info '$QPDF' | grep -q 'x86_64 arm64\|arm64 x86_64'"
check "arm64 Slice"               sh -c "lipo -info '$QPDF' | grep -q arm64"
check "x86_64 Slice"              sh -c "lipo -info '$QPDF' | grep -q x86_64"
check "Keine Homebrew-Dylibs"     sh -c "! otool -L '$QPDF' | grep -qE '/opt/homebrew|/usr/local/'"
check "--version läuft (arm64)"   sh -c "arch -arm64 '$QPDF' --version | grep -q qpdf" 
check "--check läuft"             sh -c "'$QPDF' --help >/dev/null"

for f in LICENSE-qpdf.txt NOTICE-qpdf.md LICENSE-libjpeg-turbo.md \
    LICENSE-libjpeg-mozjpeg.md LICENSE-zopfli.txt LICENSE-mozjpeg.md \
    NOTICE-mozjpeg.md NOTICE-jbig2enc.md NOTICE-libtiff.md \
    NOTICE-openjpeg.md NOTICE-harfbuzz.md; do
    check "Lizenz gebündelt: $f" test -s "$APP/Contents/Resources/ReleaseEvidence/$f"
done

# Die historische Core-Zertifizierung ersetzt nicht die aktuelle App-Abnahme.
# Prüfe das mitgebaute Gate, damit ein später geänderter Arbeitsbaum keine
# bereits gebaute App nachträglich freigeben kann. Fehlendes Gate blockiert.
GATE="$APP/Contents/Resources/ReleaseEvidence/release-acceptance.plist"
echo
echo "Feature Freeze Release Acceptance:"
ACCEPTED="$(/usr/bin/plutil -extract accepted raw -o - "$GATE" 2>/dev/null || true)"
PLAN="$(/usr/bin/plutil -extract plan raw -o - "$GATE" 2>/dev/null || true)"
if [ "$ACCEPTED" = "true" ] && [ "$PLAN" = "FEATURE_FREEZE_PLAN_2026-09-28" ]; then
    echo "  ✓ Aktuelle Feature-Freeze-Abnahme erfüllt"
else
    echo "  ✗ Aktuelle Feature-Freeze-Abnahme offen – Release blockiert"
    /usr/bin/plutil -extract blockers json -o - "$GATE" 2>/dev/null || true
    fail=1
fi

# --- Masterplan Finding 7: Release-Gate der Compression-Engine ---------------
# Es darf keine unzertifizierte Engine ausgeliefert werden. Einzige Quelle der
# Wahrheit ist CompressionEngineState.swift; hier wird sie nur GELESEN.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STATE_FILE="$ROOT/PDFTools/CompressionEngineState.swift"

echo
echo "Compression Core Certification:"
if [ ! -f "$STATE_FILE" ]; then
    echo "  ✗ CompressionEngineState.swift fehlt – Zertifizierungsstand unbekannt"
    fail=1
else
    CERT_LINE="$(grep -E '^[[:space:]]*static let compressionCoreCertified' "$STATE_FILE" || true)"
    if [ -z "$CERT_LINE" ]; then
        echo "  ✗ compressionCoreCertified nicht gefunden – Format geändert?"
        fail=1
    elif echo "$CERT_LINE" | grep -qE '^[[:space:]]*static let compressionCoreCertified[[:space:]]*=[[:space:]]*true[[:space:]]*(//.*)?$'; then
        echo "  ✓ Compression Core Certified = true"
    else
        echo "  ✗ Compression Core Certified = false – Release blockiert"
        echo "    Offene Gates:"
        sed -n '/certificationBlockers/,/\]/p' "$STATE_FILE" \
            | grep -oE '"[^"]+"' | sed 's/"//g' | sed 's/^/      - /'
        fail=1
    fi
fi

exit $fail
