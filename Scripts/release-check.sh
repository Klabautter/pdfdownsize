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
check "Helper nur arm64"          sh -c "[ \"\$(lipo -archs '$QPDF')\" = arm64 ]"
check "App nur arm64"             sh -c "[ \"\$(lipo -archs '$APP/Contents/MacOS/PDFdownsize')\" = arm64 ]"
check "Keine Homebrew-Dylibs"     sh -c "! otool -L '$QPDF' | grep -qE '/opt/homebrew|/usr/local/'"
# Masterplan N29: Ein mit Sandbox + inherit signierter Helfer lässt sich aus
# der Shell nicht direkt starten (macOS beendet ihn mit Exit 133). Dann prüft
# der Check die Signatur; die Lauffähigkeit prüft release.sh vor dem Signieren
# und das Gate am unsignierten Messbuild.
if codesign -d --entitlements - --xml "$QPDF" 2>/dev/null | grep -q 'com.apple.security.inherit'; then
    check "Helfer-Signatur gültig" codesign --verify --strict "$QPDF"
else
    check "--version läuft (arm64)" sh -c "arch -arm64 '$QPDF' --version | grep -q qpdf"
    check "--check läuft"           sh -c "'$QPDF' --help >/dev/null"
fi

for f in LICENSE-qpdf.txt NOTICE-qpdf.md \
    LICENSE-libjpeg-mozjpeg.md LICENSE-zopfli.txt LICENSE-mozjpeg.md \
    NOTICE-mozjpeg.md NOTICE-jbig2enc.md NOTICE-libtiff.md \
    NOTICE-openjpeg.md NOTICE-harfbuzz.md NOTICE-libdeflate.md; do
    check "Lizenz gebündelt: $f" test -s "$APP/Contents/Resources/ReleaseEvidence/$f"
done

# Masterplan G5: Ausgeliefert wird nur der Sandbox-Build – App und
# qpdf-Helfer (dieser mit inherit). Der Messbuild des Gates ist absichtlich
# ohne Sandbox (`--bench` liest Pfade außerhalb des Containers).
if [ "${PDFDOWNSIZE_GATE_LAEUFT:-0}" != 1 ]; then
    check "App in der Sandbox"   sh -c "codesign -d --entitlements - --xml '$APP' 2>/dev/null | grep -q 'com.apple.security.app-sandbox'"
    check "Helfer erbt Sandbox"  sh -c "codesign -d --entitlements - --xml '$QPDF' 2>/dev/null | grep -q 'com.apple.security.inherit'"
fi

# Die historische Core-Zertifizierung ersetzt nicht die aktuelle App-Abnahme.
# Prüfe das mitgebaute Gate, damit ein später geänderter Arbeitsbaum keine
# bereits gebaute App nachträglich freigeben kann. Fehlendes Gate blockiert.
GATE="$APP/Contents/Resources/ReleaseEvidence/release-acceptance.plist"
echo
echo "Release-Gate (Scripts/gate.sh):"
if [ "${PDFDOWNSIZE_GATE_LAEUFT:-0}" = 1 ]; then
    # Aufruf aus gate.sh selbst (Masterplan N8): Die Abnahme entsteht erst
    # nach diesem Check; geprüft wird sie beim Release.
    echo "  – übersprungen: Aufruf aus dem laufenden Gate"
else
ACCEPTED="$(/usr/bin/plutil -extract accepted raw -o - "$GATE" 2>/dev/null || true)"
GATE_COMMIT="$(/usr/bin/plutil -extract commit raw -o - "$GATE" 2>/dev/null || true)"
HEAD_COMMIT="$(git -C "$(cd "$(dirname "$0")/.." && pwd)" rev-parse HEAD 2>/dev/null || true)"
if [ "$ACCEPTED" = "true" ] && [ -n "$GATE_COMMIT" ] && [ "$GATE_COMMIT" = "$HEAD_COMMIT" ]; then
    echo "  ✓ Gate grün für ${GATE_COMMIT:0:12}"
else
    echo "  ✗ Kein grünes Gate für diesen Stand – Release blockiert"
    /usr/bin/plutil -extract reason raw -o - "$GATE" 2>/dev/null || true
    [ -n "$GATE_COMMIT" ] && [ "$GATE_COMMIT" != "$HEAD_COMMIT" ] \
        && echo "    Gate lief für ${GATE_COMMIT:0:12}, HEAD ist ${HEAD_COMMIT:0:12}"
    fail=1
fi
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
