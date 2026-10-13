#!/bin/bash
# Phase 2 – Corpus Bootstrap (idempotent).
# Erzeugt die externe Corpus-Verzeichnisstruktur ohne Downloads.
set -euo pipefail
# Korpuswurzel: EINE gemeinsame Auflösung für alle Skripte (Phase 9.2).
source "$(dirname "$0")/corpus-root.sh"

corpus_root "${1:-}"
ROOT="$CORPUS_ROOT"

DIRS=(
    Synthetic Golden Malformed
    RealWorld/Office RealWorld/Academic RealWorld/Government
    RealWorld/Forms RealWorld/Scans RealWorld/Special
    Stress OCR Editor Results
)

echo "Bootstrap PDFTools-TestCorpus: $ROOT"
mkdir -p "$ROOT"
for dir in "${DIRS[@]}"; do
    mkdir -p "$ROOT/$dir"
done

if [ ! -f "$ROOT/README.md" ]; then
cat > "$ROOT/README.md" <<'MD'
# PDFTools TestCorpus
Externer PDF-Testcorpus. Wird NICHT ins Git committet.
Konfigurierbar via PDFTOOLS_CORPUS_ROOT.
MD
fi

echo "✓ Bootstrap abgeschlossen:"
for dir in "${DIRS[@]}"; do echo "  $ROOT/$dir"; done
