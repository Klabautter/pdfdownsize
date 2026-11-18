#!/bin/bash
# Masterplan G3 – die sechs UI-Abläufe (PDFToolsUITests) in der Arbeitskopie.
#
# Beim ERSTEN Lauf fragt macOS, ob „PDFToolsUITests-Runner“ den Computer
# steuern darf (Systemeinstellungen → Datenschutz & Sicherheit →
# Bedienungshilfen). Ohne diese Freigabe können UI-Tests nicht klicken.
# Die Bildschirmfotos jedes Ablaufs liegen im .xcresult (Anhänge) und werden
# nach $OUT exportiert.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-${TMPDIR:-/tmp}/pdfdownsize-ui-tests}"
case "$OUT" in "$HOME/Desktop"*) echo "✗ Ausgabe nie auf dem Schreibtisch" >&2; exit 2 ;; esac
rm -rf "$OUT"; mkdir -p "$OUT"
PDFDOWNSIZE_UI_TESTS=1 "$ROOT/Scripts/test-arbeitskopie.sh" -only-testing:PDFToolsUITests \
    -resultBundlePath "$OUT/ui.xcresult"
status=$?
xcrun xcresulttool export attachments --path "$OUT/ui.xcresult" --output-path "$OUT/bilder" >/dev/null 2>&1 \
    && echo "Bildschirmfotos: $OUT/bilder"
exit $status
