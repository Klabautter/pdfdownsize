#!/bin/bash
# Release-Gate (Masterplan G1): Kein Release ohne grünes Gate.
#
#   1. Nur auf main, Arbeitsbaum sauber (das Gate prüft HEAD).
#   2. Die ReleaseGate-Suiten (Scripts/release-gate-suites.txt) – seriell,
#      aus der Arbeitskopie außerhalb des Schreibtischs.
#   3. Quick-Smoke (10 Dateien, Kompression Smart) aus derselben Kopie.
#   4. Mit --full zusätzlich die volle Testsuite (vor Minor-Releases Pflicht).
#   5. Release-Build der Arbeitskopie: bench-matrix.sh --check (Zeit- und
#      Speicherziele aus Masterplan C) und release-check.sh (Bündel, Lizenzen,
#      Engine-Zertifizierung) – Masterplan N8.
#   6. Erst wenn alles grün ist: tmp/release-acceptance.plist mit Commit-Hash
#      schreiben (tmp/ ist ignoriert, die versionierte Vorgabe
#      Scripts/release-acceptance.plist bleibt unberührt). Der Build bettet die
#      Abnahme ein, release-check.sh prüft sie gegen HEAD.
#
# Aufruf:  Scripts/gate.sh [--full] [--ui]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
FULL=0
UI=0
for arg in "$@"; do
    case "$arg" in
        --full) FULL=1 ;;
        # N14 (G3): die sechs UI-Abläufe (braucht Bildschirm und die
        # Bedienungshilfen-Freigabe für den Test-Runner).
        --ui) UI=1 ;;
        *) echo "Unbekanntes Argument: $arg (erlaubt: --full, --ui)" >&2; exit 2 ;;
    esac
done

ACCEPTANCE="$ROOT/tmp/release-acceptance.plist"

[ "$(git rev-parse --abbrev-ref HEAD)" = "main" ] || { echo "✗ Nicht auf main" >&2; exit 1; }
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    echo "✗ Arbeitsbaum nicht sauber – das Gate prüft HEAD:" >&2
    git status --short --untracked-files=no >&2
    exit 1
fi
# Masterplan N8: Auch unversionierte Dateien in den Quellordnern zählen –
# gebaut und getaggt wird der Commit, geprüft würde sonst der Arbeitsbaum.
UNTRACKED="$(git status --porcelain -- PDFTools PDFToolsTests PDFToolsUITests Vendor Scripts PDFTools.xcodeproj)"
if [ -n "$UNTRACKED" ]; then
    echo "✗ Unversionierte oder geänderte Dateien in den Quellordnern:" >&2
    echo "$UNTRACKED" >&2
    exit 1
fi
COMMIT="$(git rev-parse HEAD)"
# Eine alte Abnahme gilt nie für diesen Lauf.
mkdir -p "$ROOT/tmp"; rm -f "$ACCEPTANCE"
LOGDIR="${TMPDIR:-/tmp}"; LOGDIR="${LOGDIR%/}/pdfdownsize-gate-${COMMIT:0:12}"
mkdir -p "$LOGDIR"
echo "→ Gate für ${COMMIT:0:12}, Protokolle: $LOGDIR"

SUITES=(); NAMES=()
while IFS= read -r line; do
    line="${line%%#*}"; line="$(echo "$line" | tr -d '[:space:]')"
    [ -n "$line" ] || continue
    NAMES+=("$line")
    SUITES+=("-only-testing:PDFToolsTests/$line")
done < "$ROOT/Scripts/release-gate-suites.txt"

echo "→ ReleaseGate-Suiten (${#SUITES[@]}) …"
set +e
"$ROOT/Scripts/test-arbeitskopie.sh" "${SUITES[@]}" > "$LOGDIR/gate-suites.log" 2>&1
STATUS=$?
set -e
grep -E 'Test run with|TEST (SUCCEEDED|FAILED)|✘ Test .*(failed|issue)' "$LOGDIR/gate-suites.log" | tail -15
[ "$STATUS" -eq 0 ] || { echo "✗ ReleaseGate-Suiten rot" >&2; exit 1; }
# Masterplan N8: Ein Eintrag ohne passende Suite fährt null Tests und fällt
# sonst nicht auf (HardeningTests war ein Dateiname). Jede gelistete Suite
# muss im Protokoll als gelaufen stehen.
MISSING=()
for name in "${NAMES[@]}"; do
    grep -qE "(Suite ${name} passed|Test Suite '${name}' passed)" "$LOGDIR/gate-suites.log" \
        || MISSING+=("$name")
done
if [ "${#MISSING[@]}" -gt 0 ]; then
    echo "✗ Gelistet, aber nicht gelaufen: ${MISSING[*]}" >&2
    exit 1
fi
echo "   alle ${#NAMES[@]} gelisteten Suiten gelaufen"

ARBEITSKOPIE="$("$ROOT/Scripts/test-arbeitskopie.sh" --nur-spiegeln)"
echo "→ Quick-Smoke …"
set +e
"$ARBEITSKOPIE/Scripts/smoke-quick.sh" smart > "$LOGDIR/smoke-quick.log" 2>&1
STATUS=$?
set -e
tail -1 "$LOGDIR/smoke-quick.log"
[ "$STATUS" -eq 0 ] || { echo "✗ Quick-Smoke rot" >&2; exit 1; }

# Masterplan N8: Messsatz und Release-Check gehören ins Gate. Release-Build
# aus der Arbeitskopie (nie vom Schreibtisch), eigenes DerivedData.
GATE_DERIVED="$HOME/Library/Developer/PDFdownsize-Gate-DerivedData"
echo "→ Release-Build für Messsatz und Release-Check …"
set +e
xcodebuild build -project "$ARBEITSKOPIE/PDFTools.xcodeproj" -scheme PDFTools \
    -configuration Release -derivedDataPath "$GATE_DERIVED" \
    CLANG_COVERAGE_MAPPING=NO ENABLE_CODE_COVERAGE=NO \
    ENABLE_APP_SANDBOX=NO CODE_SIGN_ENTITLEMENTS= \
    > "$LOGDIR/release-build.log" 2>&1
# G5: Messbuild ohne Sandbox – `--bench` liest und schreibt Pfade außerhalb
# des Containers. Ausgeliefert wird der Sandbox-Build aus release.sh.
STATUS=$?
set -e
[ "$STATUS" -eq 0 ] || { echo "✗ Release-Build fehlgeschlagen ($LOGDIR/release-build.log)" >&2; exit 1; }
GATE_APP="$GATE_DERIVED/Build/Products/Release/PDFdownsize.app"

echo "→ Messsatz (bench-matrix.sh --check) …"
set +e
"$ROOT/Scripts/bench-matrix.sh" --app "$GATE_APP" --out "$LOGDIR/bench-matrix" --check \
    > "$LOGDIR/bench-matrix.log" 2>&1
STATUS=$?
set -e
cat "$LOGDIR/bench-matrix.log"
[ "$STATUS" -eq 0 ] || { echo "✗ Messsatz verfehlt die Ziele" >&2; exit 1; }

echo "→ Release-Check …"
set +e
PDFDOWNSIZE_GATE_LAEUFT=1 "$ROOT/Scripts/release-check.sh" "$GATE_APP" > "$LOGDIR/release-check.log" 2>&1
STATUS=$?
set -e
grep '✗' "$LOGDIR/release-check.log" || true
[ "$STATUS" -eq 0 ] || { echo "✗ Release-Check rot ($LOGDIR/release-check.log)" >&2; exit 1; }

if [ "$UI" -eq 1 ]; then
    echo "→ UI-Abläufe (G3) …"
    set +e
    "$ROOT/Scripts/ui-tests.sh" "$LOGDIR" > "$LOGDIR/ui.log" 2>&1
    STATUS=$?
    set -e
    grep -E "Executed|TEST (SUCCEEDED|FAILED)" "$LOGDIR/ui.log" | tail -3
    [ "$STATUS" -eq 0 ] || { echo "✗ UI-Abläufe rot ($LOGDIR/ui.log)" >&2; exit 1; }
fi

if [ "$FULL" -eq 1 ]; then
    echo "→ Volle Suite (seriell) …"
    set +e
    "$ROOT/Scripts/test-arbeitskopie.sh" > "$LOGDIR/full.log" 2>&1
    STATUS=$?
    set -e
    grep -E 'Test run with|TEST (SUCCEEDED|FAILED)' "$LOGDIR/full.log" | tail -3
    [ "$STATUS" -eq 0 ] || { echo "✗ Volle Suite rot" >&2; exit 1; }
fi

rm -f "$ACCEPTANCE"
/usr/bin/plutil -create xml1 "$ACCEPTANCE"
/usr/bin/plutil -insert accepted -bool true "$ACCEPTANCE"
/usr/bin/plutil -insert commit -string "$COMMIT" "$ACCEPTANCE"
/usr/bin/plutil -insert date -string "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$ACCEPTANCE"
/usr/bin/plutil -insert scope -string "$([ "$FULL" -eq 1 ] && echo full || echo gate)$([ "$UI" -eq 1 ] && echo +ui)" "$ACCEPTANCE"
/usr/bin/plutil -insert plan -string "MASTERPLAN_9-10_2026-11-18" "$ACCEPTANCE"
echo "✓ Gate grün – Abnahme für ${COMMIT:0:12} geschrieben"
