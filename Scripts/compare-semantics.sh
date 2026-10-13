#!/bin/zsh
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Verwendung: $0 QUELLE.pdf AUSGABE.pdf" >&2
  exit 64
fi

root="${0:A:h:h}"
source_pdf="${1:A}"
output_pdf="${2:A}"
log="$(mktemp /tmp/pdftools-semantics-XXXXXX)"
trap 'unlink "$log" 2>/dev/null || true' EXIT

export PDFTOOLS_COMPARE_SOURCE="$source_pdf"
export PDFTOOLS_COMPARE_OUTPUT="$output_pdf"
export TEST_RUNNER_PDFTOOLS_COMPARE_SOURCE="$source_pdf"
export TEST_RUNNER_PDFTOOLS_COMPARE_OUTPUT="$output_pdf"

if ! xcodebuild test \
    -project "$root/PDFTools.xcodeproj" \
    -scheme PDFTools \
    -destination "platform=macOS,arch=$(uname -m)" \
    -only-testing:PDFToolsTests/SemanticComparisonMeasurement \
    -parallel-testing-enabled NO > "$log" 2>&1; then
  rg 'Semantik:|FEHLER:|WARNUNG:|\*\* TEST FAILED \*\*' "$log" || true
  exit 1
fi
rg 'Semantik:|FEHLER:|WARNUNG:' "$log"
