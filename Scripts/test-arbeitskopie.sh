#!/bin/bash
# Tests aus einer Arbeitskopie AUSSERHALB des Schreibtischs fahren.
#
# Der von xcodebuild gebaute Test-Host (PDFdownsize) liest Testdateien über
# #filePath relativ zum Projekt. Liegt das Projekt auf dem Schreibtisch, fragt
# macOS bei jedem neu gebauten Host nach dem Ordnerzugriff. Aus der
# Arbeitskopie heraus gibt es keine Rückfrage.
#
#   1. Projekt (inkl. .git, tmp/, benchmark/) nach $ARBEITSKOPIE spiegeln.
#   2. xcodebuild test dort, mit allen übergebenen Argumenten.
#   3. Testartefakte (benchmark/) zurück ins Projekt kopieren – nur Dateien,
#      nichts wird im Projekt gelöscht.
#
# Der Korpus liegt ebenfalls auf dem Schreibtisch. Wer Korpus-Tests fährt,
# setzt PDFTOOLS_CORPUS_ROOT auf eine Kopie außerhalb (wird durchgereicht).
#
# Aufruf:  Scripts/test-arbeitskopie.sh -only-testing:PDFToolsTests/Suite …
#          Scripts/test-arbeitskopie.sh --nur-spiegeln
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARBEITSKOPIE="${PDFDOWNSIZE_ARBEITSKOPIE:-$HOME/Library/Developer/PDFdownsize-Arbeitskopie}"

mkdir -p "$ARBEITSKOPIE"
rsync -a --delete \
    --exclude 'tmp/test-build' --exclude 'tmp/release-build' \
    --exclude 'benchmark/**/outputs' --exclude '*.zip' \
    --exclude '.DS_Store' \
    "$ROOT/" "$ARBEITSKOPIE/"

[ "${1:-}" = "--nur-spiegeln" ] && { echo "$ARBEITSKOPIE"; exit 0; }

if [ -n "${PDFTOOLS_CORPUS_ROOT:-}" ]; then
    export TEST_RUNNER_PDFTOOLS_CORPUS_ROOT="$PDFTOOLS_CORPUS_ROOT"
fi

status=0
(cd "$ARBEITSKOPIE" && xcodebuild test -scheme PDFTools -destination 'platform=macOS' \
    -parallel-testing-enabled NO "$@") || status=$?

# Artefakte zurück; im Projekt wird nichts gelöscht.
rsync -a --exclude '**/outputs' "$ARBEITSKOPIE/benchmark/" "$ROOT/benchmark/"
exit $status
