#!/bin/bash
# Release-Gate (Masterplan G1): Kein Release ohne grünes Gate.
#
#   1. Nur auf main, Arbeitsbaum sauber (das Gate prüft HEAD).
#   2. Die ReleaseGate-Suiten (Scripts/release-gate-suites.txt) – seriell,
#      aus der Arbeitskopie außerhalb des Schreibtischs.
#   3. Quick-Smoke (10 Dateien, Kompression Smart) aus derselben Kopie.
#   4. Mit --full zusätzlich die volle Testsuite (vor Minor-Releases Pflicht).
#   5. Erst wenn alles grün ist: Scripts/release-acceptance.plist mit
#      Commit-Hash schreiben. Die Datei ist nicht versioniert; der Build
#      bettet sie ein, release-check.sh prüft sie gegen HEAD.
#
# Aufruf:  Scripts/gate.sh [--full]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
FULL=0
for arg in "$@"; do
    case "$arg" in
        --full) FULL=1 ;;
        *) echo "Unbekanntes Argument: $arg (erlaubt: --full)" >&2; exit 2 ;;
    esac
done

ACCEPTANCE="$ROOT/Scripts/release-acceptance.plist"

[ "$(git rev-parse --abbrev-ref HEAD)" = "main" ] || { echo "✗ Nicht auf main" >&2; exit 1; }
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    echo "✗ Arbeitsbaum nicht sauber – das Gate prüft HEAD:" >&2
    git status --short --untracked-files=no >&2
    exit 1
fi
COMMIT="$(git rev-parse HEAD)"
# Die versionierte Vorgabe sagt „nicht abgenommen“; erst ein grüner Lauf
# überschreibt sie (nach der Sauberkeitsprüfung oben).
LOGDIR="${TMPDIR:-/tmp}"; LOGDIR="${LOGDIR%/}/pdfdownsize-gate-${COMMIT:0:12}"
mkdir -p "$LOGDIR"
echo "→ Gate für ${COMMIT:0:12}, Protokolle: $LOGDIR"

SUITES=()
while IFS= read -r line; do
    line="${line%%#*}"; line="$(echo "$line" | tr -d '[:space:]')"
    [ -n "$line" ] && SUITES+=("-only-testing:PDFToolsTests/$line")
done < "$ROOT/Scripts/release-gate-suites.txt"

echo "→ ReleaseGate-Suiten (${#SUITES[@]}) …"
set +e
"$ROOT/Scripts/test-arbeitskopie.sh" "${SUITES[@]}" > "$LOGDIR/gate-suites.log" 2>&1
STATUS=$?
set -e
grep -E 'Test run with|TEST (SUCCEEDED|FAILED)|✘ Test .*(failed|issue)' "$LOGDIR/gate-suites.log" | tail -15
[ "$STATUS" -eq 0 ] || { echo "✗ ReleaseGate-Suiten rot" >&2; exit 1; }

ARBEITSKOPIE="$("$ROOT/Scripts/test-arbeitskopie.sh" --nur-spiegeln)"
echo "→ Quick-Smoke …"
set +e
"$ARBEITSKOPIE/Scripts/smoke-quick.sh" smart > "$LOGDIR/smoke-quick.log" 2>&1
STATUS=$?
set -e
tail -1 "$LOGDIR/smoke-quick.log"
[ "$STATUS" -eq 0 ] || { echo "✗ Quick-Smoke rot" >&2; exit 1; }

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
/usr/bin/plutil -insert scope -string "$([ "$FULL" -eq 1 ] && echo full || echo gate)" "$ACCEPTANCE"
/usr/bin/plutil -insert plan -string "MASTERPLAN_9-10_2026-11-18" "$ACCEPTANCE"
echo "✓ Gate grün – Abnahme für ${COMMIT:0:12} geschrieben"
