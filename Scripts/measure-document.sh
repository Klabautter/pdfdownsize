#!/bin/bash
# Ein einzelnes Dokument durch die Kompression messen.
#
# Ersetzt die Wegwerf-Sonden, die beim Untersuchen entstanden und dann im
# Testbaum liegenblieben (siehe DocumentMeasurement.swift). Der Pfad kommt
# von aussen, der Test läuft nur auf Anforderung.
#
# Nutzung:
#   Scripts/measure-document.sh <datei.pdf> [klein|smart|qualitaet|custom:<dpi>:<q>|smart:<dpi>[:<q1,q2,…>]] [ausgabe.pdf]
set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Nutzung: $0 <datei.pdf> [klein|smart|qualitaet]" >&2
    exit 64
fi

DOC="$1"
PRESET="${2:-smart}"
if [ ! -f "$DOC" ]; then
    echo "FEHLER: Datei nicht gefunden: $DOC" >&2
    exit 2
fi

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# BSD-mktemp verlangt die X am ENDE der Vorlage; ein Suffix dahinter
# lässt es fehlschlagen ("mkstemp failed ... File exists").
OUT="$(mktemp /tmp/pdftools-measure-XXXXXX)"

export PDFTOOLS_MEASURE_DOCUMENT="$(cd "$(dirname "$DOC")" && pwd)/$(basename "$DOC")"
export PDFTOOLS_MEASURE_PRESET="$PRESET"
export PDFTOOLS_MEASURE_OUTPUT="$OUT"
# Drittes Argument: Pfad, unter dem die komprimierte Datei erhalten bleibt.
export PDFTOOLS_MEASURE_KEEP="${3:-}"
# xcodebuild reicht Variablen nur mit TEST_RUNNER_-Präfix an den Testprozess durch.
for var in PDFTOOLS_MEASURE_DOCUMENT PDFTOOLS_MEASURE_PRESET PDFTOOLS_MEASURE_OUTPUT \
           PDFTOOLS_MEASURE_KEEP; do
    export "TEST_RUNNER_${var}=${!var}"
done

echo "→ Messe $(basename "$DOC") mit Stufe $PRESET …"
BUILD_STATUS=0
(cd "$PROJECT_DIR" && xcodebuild test-without-building -scheme PDFTools \
    -destination "platform=macOS,arch=$(uname -m)" \
    -only-testing:PDFToolsTests/DocumentMeasurement \
    -parallel-testing-enabled NO) > /dev/null 2>&1 || BUILD_STATUS=$?

if [ "$BUILD_STATUS" -ne 0 ]; then
    echo "FEHLER: Testprozess fehlgeschlagen (exit $BUILD_STATUS)." >&2
    rm -f "$OUT"
    exit "$BUILD_STATUS"
fi

if [ -s "$OUT" ]; then
    echo
    cat "$OUT"
    rm -f "$OUT"
else
    echo "FEHLER: keine Messung geschrieben. Wurde vorher gebaut?" >&2
    echo "        xcodebuild build-for-testing -scheme PDFTools -destination 'platform=macOS'" >&2
    exit 3
fi
