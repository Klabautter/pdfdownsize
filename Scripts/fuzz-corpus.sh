#!/bin/bash
# Masterplan D5 – Fuzz-Lauf als Dauerwächter.
#
# Nimmt N Korpusdateien, erzeugt je Datei V mutierte Varianten (Bytes kippen,
# Bereiche abschneiden, Zahlen in Wörterbüchern ersetzen) und schickt jede
# durch `--bench` mit Zeitlimit. Jeder Absturz (Signal statt Rückgabewert)
# und jeder Zeitüberlauf landet als Datei samt Notiz in $FINDINGS.
# Rückgabewerte ≠ 0 OHNE Signal sind keine Funde: Eine kaputte Datei darf
# abgelehnt werden – sie darf die App nur nicht abstürzen lassen oder hängen.
#
# Einmal vor 1.1.0, danach vor jedem Minor-Release. Abnahme: 10.000 Varianten
# (200 Dateien × 50), kein Absturz, kein Hänger.
#
# Aufruf:
#   Scripts/fuzz-corpus.sh --app <PDFdownsize.app> [--files 200] [--variants 50]
#                          [--timeout auto|SEKUNDEN] [--corpus DIR] [--work DIR] [--seed N]
#
# Zeitlimit (Masterplan N6): Vorgabe „auto“ staffelt nach Größe der Variante –
# 60 s bis 5 MB, darüber 180 s. Mit festen 60 s lieferte eine 32-MB-Variante
# von statab einen Scheinfund (54 s, erfolgreich).
#
# Läuft nie vom Schreibtisch aus: Arbeitsverzeichnis, Varianten und Ausgaben
# liegen unter --work (Vorgabe $TMPDIR/pdfdownsize-fuzz), Funde zusätzlich
# unter tmp/fuzz-findings/ im Projekt.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP=""
FILES=200
VARIANTS=50
TIMEOUT=auto
SEED=1
CORPUS="${PDFDOWNSIZE_KORPUS:-$HOME/Library/Developer/PDFdownsize-Korpus}/PDF_Tools-Testcorpus"
WORK="${TMPDIR:-/tmp}/pdfdownsize-fuzz"

while [ $# -gt 0 ]; do
    case "$1" in
        --app) APP="$2"; shift 2 ;;
        --files) FILES="$2"; shift 2 ;;
        --variants) VARIANTS="$2"; shift 2 ;;
        --timeout) TIMEOUT="$2"; shift 2 ;;
        --corpus) CORPUS="$2"; shift 2 ;;
        --work) WORK="$2"; shift 2 ;;
        --seed) SEED="$2"; shift 2 ;;
        *) echo "Unbekannt: $1" >&2; exit 2 ;;
    esac
done
# N28: `--timeout abc` hieß „kein Limit" (perl alarm mit 0). Nur auto oder
# eine ganze Zahl ab 1 gilt.
case "$TIMEOUT" in
    auto) ;;
    ''|*[!0-9]*|0*) echo "✗ --timeout erwartet auto oder Sekunden ≥ 1, nicht „$TIMEOUT“" >&2; exit 2 ;;
esac
[ -x "$APP/Contents/MacOS/PDFdownsize" ] || { echo "✗ --app fehlt oder ist kein PDFdownsize.app" >&2; exit 2; }
[ -d "$CORPUS" ] || { echo "✗ Korpus fehlt: $CORPUS" >&2; exit 2; }
case "$CORPUS$WORK" in *"$HOME/Desktop"*) echo "✗ Korpus und Arbeitsordner nie auf dem Schreibtisch" >&2; exit 2 ;; esac

FINDINGS="$ROOT/tmp/fuzz-findings"
mkdir -p "$WORK/variants" "$WORK/out" "$FINDINGS"
cd "$WORK"
BIN="$APP/Contents/MacOS/PDFdownsize"

# Dateien deterministisch auswählen (sortiert, gleichmäßig verteilt).
LIST="$WORK/files.txt"
find -L "$CORPUS" -type f -iname '*.pdf' -size -40M | sort > "$WORK/all.txt"
TOTAL=$(wc -l < "$WORK/all.txt" | tr -d ' ')
[ "$TOTAL" -gt 0 ] || { echo "✗ keine PDFs im Korpus" >&2; exit 2; }
awk -v n="$FILES" -v t="$TOTAL" 'BEGIN{step=(t>n)?t/n:1} {if (NR>=next_pick) {print; next_pick+=step}}' "$WORK/all.txt" | head -n "$FILES" > "$LIST"

MUTATE="$WORK/mutate.py"
cat > "$MUTATE" <<'PY'
import random, re, sys
src, dst, seed = sys.argv[1], sys.argv[2], int(sys.argv[3])
rng = random.Random(seed)
data = bytearray(open(src, 'rb').read())
kind = seed % 3
if kind == 0 and data:            # Bytes kippen
    for _ in range(rng.randint(1, 64)):
        i = rng.randrange(len(data)); data[i] = rng.randrange(256)
elif kind == 1 and len(data) > 16:  # Bereich abschneiden oder entfernen
    a = rng.randrange(len(data)); b = min(len(data), a + rng.randint(1, max(1, len(data) // 20)))
    data = data[:a] if rng.random() < 0.3 else data[:a] + data[b:]
else:                              # Zahlen in Wörterbüchern ersetzen
    text = bytes(data)
    numbers = [m.span() for m in re.finditer(rb'(?<=[/\[\s])-?\d+(?=[\s/\]>])', text[:4_000_000])]
    for _ in range(min(len(numbers), rng.randint(1, 40))):
        s, e = numbers[rng.randrange(len(numbers))]
        repl = rng.choice([b'0', b'-1', b'2147483647', b'99999999999', str(rng.randint(0, 9999)).encode()])
        text = text[:s] + repl + text[e:]
    data = bytearray(text)
open(dst, 'wb').write(data)
PY

run_one() {   # $1 = Variante; Rückgabe: Zeile für das Protokoll
    local v="$1" out="$WORK/out/$(basename "$1").out.pdf" rc
    local limit="$TIMEOUT"
    if [ "$limit" = auto ]; then
        limit=60
        [ "$(stat -f %z "$v")" -gt $((5 * 1024 * 1024)) ] && limit=180
    fi
    perl -e 'alarm shift; exec @ARGV' "$limit" "$BIN" --bench "$v" --mode smart \
        --report "$WORK/out/r.json" --out "$out" >/dev/null 2>&1 && rc=0 || rc=$?
    rm -f "$out" "$WORK/out/r.json"
    echo "$rc"
}

done_count=0; crashes=0; hangs=0
seed=$SEED
while IFS= read -r file; do
    for ((k = 0; k < VARIANTS; k++)); do
        seed=$((seed + 1))
        v="$WORK/variants/v-$seed.pdf"
        python3 -I "$MUTATE" "$file" "$v" "$seed"
        rc=$(run_one "$v")
        done_count=$((done_count + 1))
        # 142 = SIGALRM (Zeitlimit), >128 sonst = Signal (Absturz).
        if [ "$rc" -eq 142 ]; then
            hangs=$((hangs + 1)); cp "$v" "$FINDINGS/hang-$seed.pdf"
            echo "hang seed=$seed quelle=$file" >> "$FINDINGS/funde.txt"
        elif [ "$rc" -gt 128 ]; then
            crashes=$((crashes + 1)); cp "$v" "$FINDINGS/crash-$seed.pdf"
            echo "crash rc=$rc seed=$seed quelle=$file" >> "$FINDINGS/funde.txt"
        fi
        rm -f "$v"
        [ $((done_count % 250)) -eq 0 ] && echo "… $done_count Varianten, $crashes Abstürze, $hangs Hänger"
    done
done < "$LIST"

echo "Fertig: $done_count Varianten, $crashes Abstürze, $hangs Hänger (Funde: $FINDINGS)"
[ "$crashes" -eq 0 ] && [ "$hangs" -eq 0 ]
