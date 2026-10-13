#!/bin/bash
# Quick-Smoke: 10 Dateien, ~10-15 Min statt 5-8h Voll-Lauf.
# Je eine Datei pro Klasse (born-digital, vector, mixed, scan, photo).
# Voll-Benchmark (Core235/Smoke-30) nur nach Bündeln von 3-4 Optimierungen.
# Aufruf: ./Scripts/smoke-quick.sh [smart|klein|qualitaet]
set -euo pipefail

PRESET="${1:-smart}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CORPUS="$HOME/PDFTools-TestCorpus/RealWorld"

FILES=(
  "$CORPUS/IRS/f1024.pdf"
  "$CORPUS/EU/0193ed5f-1445-41a7-bb02-a82ded25b575_en.pdf"
  "$CORPUS/CVF/Lin_Multi-Layer_Visual_Feature_Fusion_in_Multimodal_LLMs_Methods_Analysis_and_CVPR_2025_paper.pdf"
  "$CORPUS/arXiv/1502.03167.pdf"
  "$CORPUS/NASA/20090029214.pdf"
  "$CORPUS/NIST/NIST_QMS_Supplier_audit_response_letter-FY26_6May2026.pdf"
  "$CORPUS/GovInfo/CREC-2024-01-09.pdf"
  "$CORPUS/arXiv/1409.1556.pdf"
  "$CORPUS/NASA/HEALED_Buescher_2024_vFinal.pdf"
  "$CORPUS/NIST/SP.800-207.pdf"
)

echo "Quick-Smoke: ${#FILES[@]} Dateien, Preset=$PRESET"
echo "Voller Lauf (Core235/Smoke) nur nach 3-4 Optimierungen."
echo

PASS=0; FAIL=0
for f in "${FILES[@]}"; do
  if [ ! -f "$f" ]; then
    echo "FAIL (fehlt): $f"
    FAIL=$((FAIL+1))
    continue
  fi
  echo "→ $(basename "$f") ..."
  STATUS=0
  OUT_TXT="$("$ROOT/Scripts/measure-document.sh" "$f" "$PRESET" 2>&1)" || STATUS=$?
  echo "$OUT_TXT"
  if [ "$STATUS" -ne 0 ] || [[ "$OUT_TXT" == *FEHLER* ]]; then
    echo "FAIL: $f"
    FAIL=$((FAIL+1))
  else
    PASS=$((PASS+1))
  fi
  echo
done

echo "Quick-Smoke fertig: $PASS ok, $FAIL fail von ${#FILES[@]}"
[ "$FAIL" -eq 0 ]
