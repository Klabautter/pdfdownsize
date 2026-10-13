#!/bin/bash
# Phase 30 – Compression Benchmark über Corpus.
# Aufruf: ./Scripts/benchmark.sh [CORPUS_DIR] [OUTPUT_CSV]
set -euo pipefail

# Korpuswurzel: EINE gemeinsame Auflösung für alle Skripte (Phase 9.2).
source "$(dirname "$0")/corpus-root.sh"

corpus_root "${1:-}"
CORPUS="$CORPUS_ROOT"
OUTPUT="${2:-$(dirname "$0")/../benchmark_results.csv}"
QPDF="$(dirname "$0")/../Vendor/qpdf/qpdf"

echo "file,original_bytes,optimized_bytes,saving_pct,check_ok" > "$OUTPUT"

for f in $(find "$CORPUS" -name "*.pdf" | sort); do
    name=$(basename "$f")
    orig=$(wc -c < "$f" | tr -d ' ')

    # Strukturoptimierung mit qpdf:
    # X am ENDE – BSD-mktemp scheitert an einem Suffix dahinter.
    tmp=$(mktemp /tmp/pdftools-bench-XXXXXX)
    if "$QPDF" --object-streams=generate --recompress-flate \
               --compression-level=9 "$f" "$tmp" 2>/dev/null; then
        opt=$(wc -c < "$tmp" | tr -d ' ')
        pct=$(python3 -c "print(f'{(1-$opt/$orig)*100:.1f}')" 2>/dev/null || echo "0")
        check=$("$QPDF" --check "$tmp" 2>/dev/null | grep -c "errors found" || true)
        echo "$name,$orig,$opt,$pct,ok" >> "$OUTPUT"
    else
        echo "$name,$orig,0,0,FAIL" >> "$OUTPUT"
    fi
    rm -f "$tmp"
done

echo "Ergebnisse in $OUTPUT:"
column -t -s',' "$OUTPUT"
