#!/bin/bash
# Masterplan G3 – die sechs UI-Abläufe (PDFToolsUITests) in der Arbeitskopie.
#
# Beim ERSTEN Lauf fragt macOS, ob „PDFToolsUITests-Runner“ den Computer
# steuern darf (Systemeinstellungen → Datenschutz & Sicherheit →
# Bedienungshilfen). Ohne diese Freigabe können UI-Tests nicht klicken.
# Die Bildschirmfotos jedes Ablaufs liegen im .xcresult (Anhänge) und werden
# nach <Ordner>/pdfdownsize-ui-tests exportiert (Standard: $TMPDIR).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Masterplan N9: Das Argument ist ein Elternordner. Geleert wird nur der
# eigene Unterordner `pdfdownsize-ui-tests`, und nur, wenn er die eigene
# Markierung trägt – `ui-tests.sh ~/Documents` löschte vorher den Ordner.
BASE="${1:-${TMPDIR:-/tmp}}"
BASE="${BASE%/}"
case "$BASE" in "$HOME/Desktop"*) echo "✗ Ausgabe nie auf dem Schreibtisch" >&2; exit 2 ;; esac
[ -d "$BASE" ] || { echo "✗ Ordner fehlt: $BASE" >&2; exit 2; }
OUT="$BASE/pdfdownsize-ui-tests"
MARK=".pdfdownsize-ui-tests"
if [ -e "$OUT" ]; then
    if [ ! -f "$OUT/$MARK" ]; then
        echo "✗ $OUT gehört nicht zu ui-tests.sh (Markierung fehlt) – nichts gelöscht" >&2
        exit 2
    fi
    rm -rf "$OUT"
fi
mkdir -p "$OUT" && touch "$OUT/$MARK"
PDFDOWNSIZE_UI_TESTS=1 "$ROOT/Scripts/test-arbeitskopie.sh" -only-testing:PDFToolsUITests \
    -resultBundlePath "$OUT/ui.xcresult"
status=$?
xcrun xcresulttool export attachments --path "$OUT/ui.xcresult" --output-path "$OUT/bilder" >/dev/null 2>&1 \
    && echo "Bildschirmfotos: $OUT/bilder"
exit $status
