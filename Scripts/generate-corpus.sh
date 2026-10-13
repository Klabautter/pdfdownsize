#!/bin/bash
# Masterplan Finding 19 / Schritt 10 – Golden- und Malformed-Korpus erzeugen.
#
# Beide Korpora sind GENERIERT, nicht eingecheckt: reproduzierbar, im Review
# lesbar und immer synchron zu ihren Erwartungen (Golden/manifest.json,
# Malformed/manifest.json).
#
# Nutzung:
#   Scripts/generate-corpus.sh [corpus-root]
#     corpus-root: Argument → PDFTOOLS_CORPUS_ROOT → Vorgabe (Scripts/corpus-root.sh)
set -euo pipefail

# Korpuswurzel: EINE gemeinsame Auflösung für alle Skripte (Phase 9.2).
source "$(dirname "$0")/corpus-root.sh"

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CORPUS_ARG="${1:-}"

if [ -n "$CORPUS_ARG" ]; then
    export PDFTOOLS_CORPUS_ROOT="$CORPUS_ARG"
fi
# Auflösen NACH dem Export, damit ein Argument sich durchsetzt. Bricht ab,
# wenn die Wurzel fehlt – ein Lauf über null Dokumente meldete sonst Erfolg.
corpus_root_required

export PDFTOOLS_GENERATE_CORPUS=1
for var in PDFTOOLS_CORPUS_ROOT PDFTOOLS_GENERATE_CORPUS; do
    if [ -n "${!var:-}" ]; then
        export "TEST_RUNNER_${var}=${!var}"
    fi
done

echo "→ Erzeuge Golden- und Malformed-Korpus"
echo "→ Corpus Root: $CORPUS_ROOT  ($CORPUS_ROOT_SOURCE)"

cd "$PROJECT_DIR"

xcodebuild test \
    -project PDFTools.xcodeproj \
    -scheme PDFTools \
    -configuration Debug \
    -destination 'platform=macOS,arch=arm64' \
    '-only-testing:PDFToolsTests/CorpusGeneratorTests/generateIntoConfiguredCorpus()' \
    2>&1 | tee /tmp/pdftools-generate-corpus.log
# Exitcode direkt nach der Pipeline lesen (siehe run-matrix.sh).
EXIT="${PIPESTATUS[0]}"

grep -E "Corpus generiert|Golden:|Malformed:|error:" \
    /tmp/pdftools-generate-corpus.log || true
if [ "$EXIT" -ne 0 ]; then
    echo "✗ Korpus-Erzeugung FEHLGESCHLAGEN (Exit $EXIT) – Log: /tmp/pdftools-generate-corpus.log"
    exit "$EXIT"
fi
echo "✓ Korpus erzeugt"
