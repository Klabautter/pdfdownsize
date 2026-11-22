#!/bin/bash
# Masterplan C – Messsatz für Zeit und Speicher (Release, --bench, Stufe Smart;
# byrne_euclid zusätzlich Klein). Schreibt eine CSV je Lauf und prüft mit
# --check die Ziele aus dem Plan.
#
#   Scripts/bench-matrix.sh --app <PDFdownsize.app> [--out DIR] [--check] [--ohne-ipcc]
#
# Die Dateien kommen aus der Korpus-Kopie unter ~/Library/Developer/
# PDFdownsize-Korpus (Scripts/test-arbeitskopie.sh legt sie an) – nie vom
# Schreibtisch. Arbeitsverzeichnis und Ausgaben liegen unter --out.
set -uo pipefail

APP=""; OUT="${TMPDIR:-/tmp}/pdfdownsize-bench-matrix"; CHECK=0; IPCC=1
while [ $# -gt 0 ]; do
    case "$1" in
        --app) APP="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        --check) CHECK=1; shift ;;
        --ohne-ipcc) IPCC=0; shift ;;
        *) echo "Unbekannt: $1" >&2; exit 2 ;;
    esac
done
BIN="$APP/Contents/MacOS/PDFdownsize"
[ -x "$BIN" ] || { echo "✗ --app fehlt" >&2; exit 2; }
K="${PDFDOWNSIZE_KORPUS:-$HOME/Library/Developer/PDFdownsize-Korpus}"
case "$OUT" in "$HOME/Desktop"*) echo "✗ --out nie auf dem Schreibtisch" >&2; exit 2 ;; esac
mkdir -p "$OUT"; cd "$OUT" || exit 2

# name|datei|modus|ziel_sekunden|ziel_mb (0 = kein Speicherziel)
# Kalibriert auf den abgenommenen 1.1.0-Release-Stand (mit Reserve für
# Dauerlast-Schwankungen; fängt echte Rückschritte zuverlässig ab).
MATRIX="statab|$K/Smoke_30/01_BornDigital_Text/RealWorld__statab_2012__c6c995b0.pdf|smart|28|1200
euclid|$K/PDF_Tools-Testcorpus/RealWorld/Archive/byrne_euclid_1847.pdf|smart|6|0
euclid-klein|$K/PDF_Tools-Testcorpus/RealWorld/Archive/byrne_euclid_1847.pdf|klein|55|0
audubon|$K/PDF_Tools-Testcorpus/RealWorld/Archive/audubon_birds_of_america.pdf|smart|22|0
usgs_light_003|$K/Smoke_30/11_Maps_CAD_Technical/USGS_HTMC__09f3e5b944__usgs_light_003_USGS_1_100000-scale_Quadrangle_for_Boston_MA_1989.pdf|smart|48|0"
[ "$IPCC" = 1 ] && MATRIX="$MATRIX
ipcc|$K/PDF_Tools-Testcorpus/RealWorld/IPCC/IPCC_AR6_WGI_FullReport.pdf|smart|360|1850"

CSV="$OUT/bench-$(date +%Y%m%d-%H%M%S).csv"
echo "name,modus,eingabe_bytes,ausgabe_bytes,ersparnis_prozent,sekunden,spitze_mb,ziel_sekunden,ziel_mb,ok" > "$CSV"
fail=0
while IFS='|' read -r name file mode goalS goalMB; do
    [ -f "$file" ] || { echo "✗ fehlt: $file" >&2; fail=1; continue; }
    report="$OUT/$name.json"; out="$OUT/$name.out.pdf"
    # N28: Ein Bericht eines früheren Laufs darf nie für diesen gelten.
    rm -f "$report" "$out"
    /usr/bin/time -l "$BIN" --bench "$file" --mode "$mode" --report "$report" --out "$out" \
        > /dev/null 2> "$OUT/$name.time"
    status=$?
    secs=$(python3 -c "import json;print(round(json.load(open('$report'))['wall_ms']/1000,1))" 2>/dev/null || echo NaN)
    inb=$(python3 -c "import json;print(json.load(open('$report'))['input_bytes'])" 2>/dev/null || echo 0)
    outb=$(python3 -c "import json;print(json.load(open('$report'))['output_bytes'])" 2>/dev/null || echo 0)
    peak=$(awk '/maximum resident set size/ {printf "%d", $1/1048576}' "$OUT/$name.time")
    saved=$(python3 -c "print(round(100*(1-$outb/max($inb,1)),1))")
    ok=1
    # N28: Ein gescheiterter Lauf besteht nie, auch wenn ein Bericht da ist.
    if [ "$status" -ne 0 ] || [ ! -s "$report" ]; then
        echo "✗ $name: Lauf endete mit Code $status$([ -s "$report" ] || echo ', ohne Bericht')" >&2
        ok=0
    fi
    python3 -c "import sys; sys.exit(0 if $secs <= $goalS else 1)" 2>/dev/null || ok=0
    [ "$goalMB" -gt 0 ] && [ "${peak:-0}" -gt "$goalMB" ] && ok=0
    [ "$ok" = 0 ] && fail=1
    echo "$name,$mode,$inb,$outb,$saved,$secs,$peak,$goalS,$goalMB,$ok" >> "$CSV"
    printf '%-16s %-6s %6s s %6s MB  %5s %%  %s\n' "$name" "$mode" "$secs" "$peak" "$saved" "$([ $ok = 1 ] && echo ✓ || echo ✗)"
    rm -f "$out"
done <<< "$MATRIX"
echo "CSV: $CSV"
[ "$CHECK" = 1 ] && exit $fail
exit 0
