#!/bin/bash
# Phase 12 – Abschluss-Zertifizierung, vollständig und am Stück.
#
# Der Plan verlangt: „Erst jetzt alles vollständig erneut ausführen. Keine
# alten Reports wiederverwenden." Genau das tut dieses Skript – in EINEM
# Durchgang, damit alle Punkte denselben Codestand belegen. Neun Aufrufe von
# Hand über Stunden verteilt sind keine Zertifizierung, sondern neun
# Momentaufnahmen.
#
# Reihenfolge nach Aufwand: Was schnell fehlschlägt, schlägt zuerst fehl –
# ein Fehler in den Unit-Tests soll nicht erst nach zwei Stunden Korpuslauf
# auffallen.
#
# FORTSETZEN NACH ABBRUCH
#
# Der Durchgang dauert Stunden. Wird er unterbrochen – Sitzungsende, Neustart,
# versehentliches Ctrl-C –, wäre es Unsinn, die bereits bestandenen Punkte
# noch einmal zu fahren. Genau das ist einmal passiert: fünf Punkte waren
# durch, der FULL-Korpus lief, dann endete die Sitzung.
#
# Fortsetzen ist NUR zulässig, solange der Codestand derselbe ist. Deshalb
# steht er im Protokollverzeichnis, und `--fortsetzen` prüft ihn, bevor es
# etwas überspringt. Bei abweichendem Stand bricht es ab, statt eine
# Zertifizierung aus zwei verschiedenen Ständen zusammenzusetzen.
#
# Nutzung:
#   Scripts/certify.sh [corpus-root]
#   Scripts/certify.sh --fortsetzen <protokollverzeichnis> [corpus-root]
set -uo pipefail

source "$(dirname "$0")/corpus-root.sh"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

RESUME_DIR=""
if [ "${1:-}" = "--fortsetzen" ]; then
    RESUME_DIR="${2:-}"
    shift 2
    if [ ! -d "$RESUME_DIR" ]; then
        echo "FEHLER: Protokollverzeichnis nicht gefunden: $RESUME_DIR" >&2
        exit 64
    fi
fi
corpus_root_required "${1:-}"

if [ -n "$RESUME_DIR" ]; then
    LOGDIR="$RESUME_DIR"
else
    LOGDIR="$(mktemp -d /tmp/pdftools-certify-XXXXXX)"
fi
RESULT="$LOGDIR/ergebnis.txt"
[ -z "$RESUME_DIR" ] && : > "$RESULT"

# Der Codestand, den diese Zertifizierung belegt. Ändert sich währenddessen
# etwas, ist das Ergebnis wertlos – deshalb am Ende die Gegenprobe.
cd "$PROJECT_DIR"
STATE_BEFORE=$(find PDFTools PDFToolsTests Vendor/pdfcore/src \
    -name "*.swift" -o -name "*.cc" -o -name "*.h" 2>/dev/null \
    | sort | xargs shasum | shasum | awk '{print $1}')

note() { echo "$1" | tee -a "$RESULT"; }
step() { echo; note "━━ $1"; }

if [ -n "$RESUME_DIR" ]; then
    VORHER=$(grep -m1 '^Codestand:' "$RESULT" | awk '{print $2}')
    if [ "$VORHER" != "$STATE_BEFORE" ]; then
        echo "FEHLER: Der Code hat sich seit dem abgebrochenen Durchgang geändert." >&2
        echo "        damals: $VORHER" >&2
        echo "        jetzt:  $STATE_BEFORE" >&2
        echo "        Eine Zertifizierung aus zwei Ständen wäre keine. Neu starten." >&2
        exit 3
    fi
    note ""
    note "── fortgesetzt am $(date '+%Y-%m-%d %H:%M:%S'), Codestand unverändert"
fi

# Ein Punkt gilt als erledigt, wenn er im Protokoll bereits mit PASS steht.
erledigt() {
    [ -n "$RESUME_DIR" ] && grep -q "^  $1: PASS$" "$RESULT"
}

note "Phase 12 – Abschluss-Zertifizierung"
note "Beginn:     $(date '+%Y-%m-%d %H:%M:%S')"
note "Korpus:     $CORPUS_ROOT  ($CORPUS_ROOT_SOURCE)"
note "Codestand:  $STATE_BEFORE"
note "Protokolle: $LOGDIR"

FAILED=""
record() {  # name, exit-code
    if [ "$2" -eq 0 ]; then note "  $1: PASS"
    else note "  $1: FEHLGESCHLAGEN (Exit $2)"; FAILED="$FAILED $1"; fi
}

# --- 12.1 Sauberes Umfeld ---------------------------------------------------
step "12.1 Sauberes Umfeld"
if erledigt "Debug-Build" && erledigt "Release-Build"; then
    note "  übersprungen (bereits bestanden) – DerivedData bleibt, sonst wären"
    note "  die Bauprodukte weg, auf denen die folgenden Punkte laufen"
else
rm -rf ~/Library/Developer/Xcode/DerivedData/PDFTools-*
note "  DerivedData entfernt"

xcodebuild build-for-testing -scheme PDFTools -destination 'platform=macOS' \
    > "$LOGDIR/build-debug.log" 2>&1
record "Debug-Build" $?
W=$(grep 'warning:' "$LOGDIR/build-debug.log" | grep -viE 'swiftmacro|appintents' | sort -u | wc -l | tr -d ' ')
note "  Warnungen: $W"
[ "$W" -gt 0 ] && FAILED="$FAILED Debug-Warnungen"

xcodebuild build -scheme PDFTools -destination 'platform=macOS' -configuration Release \
    > "$LOGDIR/build-release.log" 2>&1
record "Release-Build" $?
W=$(grep 'warning:' "$LOGDIR/build-release.log" | grep -viE 'swiftmacro|appintents' | sort -u | wc -l | tr -d ' ')
note "  Warnungen: $W"
[ "$W" -gt 0 ] && FAILED="$FAILED Release-Warnungen"
fi

# --- 12.2 Unit + Integration ------------------------------------------------
step "12.2 Unit + Integration"
if erledigt "Unit-Tests"; then note "  übersprungen (bereits bestanden)"; else
NSUnbufferedIO=YES xcodebuild test-without-building -scheme PDFTools \
    -destination 'platform=macOS' > "$LOGDIR/tests.log" 2>&1
E=$?
P=$(grep -c 'Test case .*passed' "$LOGDIR/tests.log")
F=$(grep -c 'Test case .*failed' "$LOGDIR/tests.log")
U=$(grep -oE "Test case '[^']*'" "$LOGDIR/tests.log" | sort -u | wc -l | tr -d ' ')
note "  $P bestanden, $F fehlgeschlagen, $U eindeutige Tests"
record "Unit-Tests" $E
grep "Test case .*failed" "$LOGDIR/tests.log" | sed -E "s/.*Test case '([^']*)'.*/    ✗ \1/" | sort -u | tee -a "$RESULT"
fi

# --- 12.4 Golden-Erwartungen ------------------------------------------------
step "12.4 Golden-Erwartungen"
if erledigt "Golden-Erwartungen"; then note "  übersprungen (bereits bestanden)"; else
NSUnbufferedIO=YES xcodebuild test-without-building -scheme PDFTools \
    -destination 'platform=macOS' -parallel-testing-enabled NO \
    -only-testing:PDFToolsTests/CorpusGeneratorTests > "$LOGDIR/golden.log" 2>&1
record "Golden-Erwartungen" $?
fi

# --- 12.3 FAST-Korpus -------------------------------------------------------
step "12.3 FAST-Korpus"
if erledigt "FAST-Korpus"; then note "  übersprungen (bereits bestanden)"; else
./Scripts/run-matrix.sh fast > "$LOGDIR/fast.log" 2>&1
record "FAST-Korpus" $?
fi

# --- 12.9 Belastungskorpus --------------------------------------------------
step "12.9 Belastungskorpus"
if erledigt "Belastungskorpus"; then note "  übersprungen (bereits bestanden)"; else
./Scripts/run-matrix.sh stress > "$LOGDIR/stress.log" 2>&1
record "Belastungskorpus" $?
fi

# --- 12.5 + 12.7 FULL-Korpus (alle fünf Kompressionsstufen) -----------------
step "12.5 + 12.7 FULL-Korpus"
if erledigt "FULL-Korpus"; then note "  übersprungen (bereits bestanden)"; else
./Scripts/run-matrix.sh full > "$LOGDIR/full.log" 2>&1
record "FULL-Korpus" $?
fi

# --- 12.8 Estimator-Labor ---------------------------------------------------
step "12.8 Estimator-Labor"
if erledigt "Estimator-Labor"; then note "  übersprungen (bereits bestanden)"; else
./Scripts/accuracy-lab.sh full > "$LOGDIR/estimator.log" 2>&1
record "Estimator-Labor" $?
fi

# --- Gegenprobe: hat sich der Code während des Laufs geändert? --------------
step "Gegenprobe"
STATE_AFTER=$(find PDFTools PDFToolsTests Vendor/pdfcore/src \
    -name "*.swift" -o -name "*.cc" -o -name "*.h" 2>/dev/null \
    | sort | xargs shasum | shasum | awk '{print $1}')
if [ "$STATE_BEFORE" = "$STATE_AFTER" ]; then
    note "  Codestand unverändert – die Zertifizierung gilt für $STATE_BEFORE"
else
    note "  CODESTAND VERÄNDERT ($STATE_BEFORE → $STATE_AFTER)"
    note "  Die Zertifizierung belegt keinen einheitlichen Stand und ist zu wiederholen."
    FAILED="$FAILED Codestand"
fi

step "Ergebnis"
note "Ende: $(date '+%Y-%m-%d %H:%M:%S')"
if [ -z "$FAILED" ]; then
    note "PHASE 12 BESTANDEN"
    exit 0
else
    note "PHASE 12 NICHT BESTANDEN –$FAILED"
    exit 1
fi
