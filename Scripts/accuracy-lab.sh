#!/bin/bash
# Masterplan Schritt 7 – Compression Accuracy Lab.
#
# Misst über den Korpus, wie gut die Schätzung des Estimators die tatsächliche
# Ausgabegröße trifft, und schreibt COMPRESSION_ACCURACY_LAB.md in
# <corpus>/Results/. Erst aus diesen Daten werden Accuracy-Gates abgeleitet –
# vorher gibt es bewusst keine Zahlenvorgabe.
#
# Nutzung:
#   Scripts/accuracy-lab.sh [suite] [corpus-root]
#     suite:       fast | full | stress   (Default: fast)
set -euo pipefail

# Korpuswurzel: EINE gemeinsame Auflösung für alle Skripte (Phase 9.2).
source "$(dirname "$0")/corpus-root.sh"

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SUITE="${1:-${PDFTOOLS_SUITE:-fast}}"
CORPUS_ARG="${2:-}"

if [ -n "$CORPUS_ARG" ]; then
    export PDFTOOLS_CORPUS_ROOT="$CORPUS_ARG"
fi
# Auflösen NACH dem Export, damit ein Argument sich durchsetzt. Bricht ab,
# wenn die Wurzel fehlt – ein Lauf über null Dokumente meldete sonst Erfolg.
corpus_root_required
export PDFTOOLS_SUITE="$SUITE"
# Ausdrückliche Anforderung. Ohne sie läuft das Labor nicht – es fährt den
# ganzen Korpus durch fünf Voreinstellungen und gehört nicht in eine
# gewöhnliche Regression.
export PDFTOOLS_ACCURACY_LAB=1

for var in PDFTOOLS_ACCURACY_LAB PDFTOOLS_CORPUS_ROOT PDFTOOLS_SUITE PDFTOOLS_OPERATION \
           PDFTOOLS_SEED PDFTOOLS_KEEP_OUTPUTS PDFTOOLS_CORPUS_ID; do
    if [ -n "${!var:-}" ]; then
        export "TEST_RUNNER_${var}=${!var}"
    fi
done

# Release wie beim Korpuslauf, und aus demselben gemessenen Grund: Der Debug-
# Build braucht je Operation ein Vielfaches. Das Labor misst BYTES – die sind
# in beiden Konfigurationen dieselben –, also kostet Debug hier nur Zeit.
# Umschalten mit: PDFTOOLS_CONFIGURATION=Debug
echo "→ Compression Accuracy Lab (Suite: $SUITE, Konfiguration: ${PDFTOOLS_CONFIGURATION:-Release})"
echo "→ Corpus Root: $CORPUS_ROOT  ($CORPUS_ROOT_SOURCE)"

cd "$PROJECT_DIR"

# `@testable import` braucht ein Modul, das mit aktivierter Testbarkeit
# gebaut wurde. Im Debug ist das die Voreinstellung, im Release nicht – dort
# scheitert das Testziel sonst mit „unable to resolve Swift module dependency
# to a compatible module: 'PDFTools'", während die App selbst sauber baut.
# `run-matrix.sh` löst das seit je so; hier fehlte es.
CONFIGURATION="${PDFTOOLS_CONFIGURATION:-Release}"
TESTABILITY_FLAG=()
if [ "$CONFIGURATION" != "Debug" ]; then
    TESTABILITY_FLAG=(ENABLE_TESTABILITY=YES)
fi

xcodebuild test \
    -project PDFTools.xcodeproj \
    -scheme PDFTools \
    -configuration "$CONFIGURATION" \
    -destination 'platform=macOS,arch=arm64' \
    ${TESTABILITY_FLAG[@]+"${TESTABILITY_FLAG[@]}"} \
    '-only-testing:PDFToolsTests/CompressionAccuracyLab/measureEstimatorAccuracy()' \
    2>&1 | tee /tmp/pdftools-accuracy-lab.log
# Exitcode direkt nach der Pipeline lesen (siehe run-matrix.sh).
EXIT="${PIPESTATUS[0]}"

grep -E "Accuracy Lab|Median APE|MAPE|P90|P95|Worst|Report:|Messungen" \
    /tmp/pdftools-accuracy-lab.log || true
if [ "$EXIT" -ne 0 ]; then
    echo "✗ Accuracy Lab FEHLGESCHLAGEN (Exit $EXIT) – Log: /tmp/pdftools-accuracy-lab.log"
    exit "$EXIT"
fi
echo "✓ Accuracy Lab abgeschlossen"
