#!/bin/bash
# Speicher-Regressionen – LÄUFT ALLEIN.
#
# `MemoryRegressionTests` misst über `task_info` den Verbrauch des GESAMTEN
# Prozesses. In der Standardsuite laufen daneben rund 360 weitere Tests, deren
# Speicherbedarf in jede Messung eingeht: Derselbe Code war isoliert grün und
# in der Suite rot (gemessen 878 MB „Wachstum" gegen eine 150-MB-Schwelle).
#
# Die Schwelle aufzuweichen wäre der falsche Weg – sie ist die Aussage. Der
# Test bekommt stattdessen die Bedingungen, unter denen er messen kann.
set -uo pipefail
exec < /dev/null

cd "$(dirname "$0")/.."

echo "→ Baue Testziel …"
xcodebuild build-for-testing -project PDFTools.xcodeproj -scheme PDFTools \
    -configuration Debug -destination 'platform=macOS,arch=arm64' \
    > /tmp/memory-check-build.log 2>&1
BUILD=${PIPESTATUS[0]}
if [ "$BUILD" -ne 0 ]; then
    echo "✗ Build fehlgeschlagen – siehe /tmp/memory-check-build.log"
    exit 1
fi

echo "→ Speicher-Regressionen (ohne Parallelität) …"
xcodebuild test-without-building -project PDFTools.xcodeproj -scheme PDFTools \
    -configuration Debug -destination 'platform=macOS,arch=arm64' \
    -parallel-testing-enabled NO \
    -only-testing:PDFToolsTests/MemoryRegressionTests \
    > /tmp/memory-check.log 2>&1
STATUS=${PIPESTATUS[0]}

PASSED=$(grep -c '✔ Test ' /tmp/memory-check.log 2>/dev/null || echo 0)
FAILED=$(grep -c '✘ Test ' /tmp/memory-check.log 2>/dev/null || echo 0)
echo "   bestanden: $PASSED · fehlgeschlagen: $FAILED"

if [ "$STATUS" -eq 0 ]; then
    echo "✓ Speicher-Regressionen PASS"
else
    echo "✗ Speicher-Regressionen FAIL – siehe /tmp/memory-check.log"
    grep -E '✘|Expectation failed' /tmp/memory-check.log | head -5
fi
exit $STATUS
