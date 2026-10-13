#!/bin/bash
# Vergleicht eine bereits erzeugte PDF visuell mit ihrer Quelle.
# Nutzung: Scripts/compare-document.sh QUELLE.pdf AUSGABE.pdf
set -euo pipefail

if [ $# -ne 2 ] || [ ! -f "$1" ] || [ ! -f "$2" ]; then
    echo "Nutzung: $0 QUELLE.pdf AUSGABE.pdf" >&2
    exit 64
fi

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
OUTPUT="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
REPORT="$(mktemp /tmp/pdftools-compare-XXXXXX)"
trap 'unlink "$REPORT" 2>/dev/null || true' EXIT

export PDFTOOLS_COMPARE_SOURCE="$SOURCE"
export PDFTOOLS_COMPARE_OUTPUT="$OUTPUT"
export PDFTOOLS_COMPARE_REPORT="$REPORT"
for var in PDFTOOLS_COMPARE_SOURCE PDFTOOLS_COMPARE_OUTPUT \
           PDFTOOLS_COMPARE_REPORT; do
    export "TEST_RUNNER_${var}=${!var}"
done

if ! (cd "$PROJECT_DIR" && xcodebuild test-without-building -scheme PDFTools \
    -destination "platform=macOS,arch=$(uname -m)" \
    -only-testing:PDFToolsTests/ComparisonMeasurement \
    -parallel-testing-enabled NO) > /dev/null 2>&1; then
    echo "FEHLER: Rendervergleich ist fehlgeschlagen." >&2
    exit 3
fi

if [ ! -s "$REPORT" ]; then
    echo "FEHLER: keine Vergleichsmessung geschrieben. Zuerst build-for-testing ausführen." >&2
    exit 3
fi
cat "$REPORT"
