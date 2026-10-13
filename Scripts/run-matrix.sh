#!/bin/bash
# Monster Epic Finding 1 – Operation Matrix Runner.
#
# Dieses Skript startet AUSSCHLIESSLICH den echten PDFToolsCorpusRunner.
# Alle Operationen laufen über Production-Services (Compressor /
# MergeViewModel.assemble / PageSplitter). qpdf wird vom Runner ausschließlich
# als unabhängiger externer Output-Validator benutzt – niemals zur
# Implementierung einer Produktfunktion.
#
# Nutzung:
#   Scripts/run-matrix.sh [suite] [corpus-root]
#     suite:       fast | full | stress   (Default: fast)
#     corpus-root: Argument → PDFTOOLS_CORPUS_ROOT → Vorgabe (Scripts/corpus-root.sh)
#
# Weitere Optionen über Environment:
#   PDFTOOLS_OPERATION    Komma-Liste (z. B. "compress-smart,merge")
#   PDFTOOLS_SEED         UInt64-Seed für deterministische Stichproben
#   PDFTOOLS_KEEP_OUTPUTS 1 = Outputs zusätzlich im Run-Verzeichnis behalten
#   PDFTOOLS_CORPUS_ID    freies Label im Report
set -euo pipefail

# Korpuswurzel: EINE gemeinsame Auflösung für alle Skripte (Phase 9.2).
source "$(dirname "$0")/corpus-root.sh"

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SUITE="${1:-${PDFTOOLS_SUITE:-fast}}"
CORPUS_ARG="${2:-}"

# Konfiguration des Korpuslaufs.
#
# Default ist Release, und zwar aus einem gemessenen Grund: Derselbe Lauf
# braucht im Debug-Build 8,3 s je Operation, im Release 0,61 s – Faktor 13.
# Für die volle Suite sind das 5 Stunden gegenüber gut einer halben.
#
# Die Ergebnisse sind dabei identisch: Die Render-Metriken (CAR/SSIM/MAD/InkΔ)
# stimmen in beiden Konfigurationen auf die Nachkommastelle überein – geprüft
# an denselben Dokumenten.
#
# Was Release NICHT ersetzt: Der Debug-Build prüft Array-Grenzen und
# Integer-Overflows. Die reguläre Test-Suite läuft deshalb weiterhin in
# Debug; hier geht es um Durchsatz über tausende Dokumente.
# Umschalten mit: PDFTOOLS_CONFIGURATION=Debug
CONFIGURATION="${PDFTOOLS_CONFIGURATION:-Release}"

# @testable import verlangt Testability – in Release standardmäßig aus.
# Das Flag wird nur für diesen Lauf gesetzt, das Projekt bleibt unverändert.
# Leeres Array: Unter `set -u` ist "${ARR[@]}" bei leerem Array in älteren
# bash-Versionen ein Fehler ("unbound variable") – deshalb die
# ${ARR[@]+...}-Form, die nur expandiert, wenn das Array belegt ist.
# Getroffen hat es Debug-Läufe, bei denen ENABLE_TESTABILITY nicht nötig ist.
TESTABILITY_FLAG=()
if [ "$CONFIGURATION" != "Debug" ]; then
    TESTABILITY_FLAG=(ENABLE_TESTABILITY=YES)
fi

if [ -n "$CORPUS_ARG" ]; then
    export PDFTOOLS_CORPUS_ROOT="$CORPUS_ARG"
fi
# Auflösen NACH dem Export, damit ein Argument sich durchsetzt. Bricht ab,
# wenn die Wurzel fehlt – ein Lauf über null Dokumente meldete sonst Erfolg.
corpus_root_required
export PDFTOOLS_SUITE="$SUITE"
# Ausdrückliche Anforderung: nur damit läuft der Korpus-Runner.
export PDFTOOLS_CORPUS_RUN=1

# xcodebuild reicht Variablen nur mit TEST_RUNNER_-Präfix an den Testprozess durch.
for var in PDFTOOLS_CORPUS_RUN PDFTOOLS_CORPUS_ROOT PDFTOOLS_SUITE PDFTOOLS_OPERATION \
           PDFTOOLS_SEED PDFTOOLS_KEEP_OUTPUTS PDFTOOLS_CORPUS_ID PDFTOOLS_SHARD \
           PDFTOOLS_SHARD_GROUP PDFTOOLS_MERGE_SHARDS; do
    if [ -n "${!var:-}" ]; then
        export "TEST_RUNNER_${var}=${!var}"
    fi
done

echo "→ PDFToolsCorpusRunner (Suite: $SUITE, Konfiguration: $CONFIGURATION)"
echo "→ Corpus Root: $CORPUS_ROOT  ($CORPUS_ROOT_SOURCE)"

cd "$PROJECT_DIR"

# Build und Test sind GETRENNT.
#
# `xcodebuild test` erledigt beides in einem Lauf – dabei endete der
# Testprozess mehrfach vorzeitig ("exited before finishing"), während
# derselbe Test nach getrenntem Build vollständig durchlief. Die Trennung
# unterscheidet außerdem sauber, WAS fehlschlug: ein Übersetzungsfehler ist
# kein Korpus-Fehlschlag.
# Hinweis auf den separaten Speicherlauf – er kann hier nicht mitlaufen,
# weil er Parallelität ausschliesst (siehe Scripts/memory-check.sh).
echo "  (Speicher-Regressionen laufen separat: Scripts/memory-check.sh)"

echo "→ Baue Testziel …"
xcodebuild build-for-testing \
    -project PDFTools.xcodeproj \
    -scheme PDFTools \
    -configuration "$CONFIGURATION" \
    -destination 'platform=macOS,arch=arm64' \
    ${TESTABILITY_FLAG[@]+"${TESTABILITY_FLAG[@]}"} \
    2>&1 | tee /tmp/pdftools-corpus-build.log
BUILD_EXIT="${PIPESTATUS[0]}"

if [ "$BUILD_EXIT" -ne 0 ]; then
    echo "✗ BUILD fehlgeschlagen (Exit $BUILD_EXIT) – Log: /tmp/pdftools-corpus-build.log"
    grep -E "error:" /tmp/pdftools-corpus-build.log | head -20 || true
    exit "$BUILD_EXIT"
fi

# --- Chargen ----------------------------------------------------------------
#
# Der PDFKit-Assembler gibt Seiteninhalte nicht zurück (gemessen: 2938 MB nach
# sechs Durchläufen an einem 126-seitigen Dokument, gegenüber 71 MB beim
# libqpdf-Backend). Über tausende Operationen wächst der Prozess, bis er
# stirbt – vier Läufe endeten so.
#
# Bis zum Cutover auf libqpdf (Masterplan Schritt 11) wird der Korpus deshalb
# in Chargen abgearbeitet: Jede läuft in einem eigenen Prozess, der seinen
# Speicher am Ende vollständig zurückgibt. Das Gate bewertet anschließend die
# VEREINIGUNG aller Chargen – nicht jede Charge für sich.
#
# 0 = keine Chargen (ein Prozess für alles).
SHARDS="${PDFTOOLS_SHARDS:-0}"
if [ "$SHARDS" -eq 0 ] && [ "$SUITE" = "full" ]; then
    SHARDS=6
fi

run_corpus() {   # $1 = Beschriftung, weitere Umgebung vom Aufrufer gesetzt
    # Eigenes Ergebnisbündel je Charge. Ohne das schreiben gleichzeitig
    # laufende Chargen in dasselbe Verzeichnis unter DerivedData/Logs/Test.
    rm -rf "/tmp/pdftools-result-$1.xcresult"
    xcodebuild test-without-building \
        -project PDFTools.xcodeproj \
        -scheme PDFTools \
        -configuration "$CONFIGURATION" \
        -destination 'platform=macOS,arch=arm64' \
        -resultBundlePath "/tmp/pdftools-result-$1.xcresult" \
        "$2" \
        2>&1 | tee "/tmp/pdftools-corpus-$1.log"
    # WICHTIG: Exitcode DIREKT nach der Pipeline lesen. Ein angehängtes
    # `| grep ... || true` überschriebe PIPESTATUS – das Gate meldete dann
    # immer PASS, auch wenn der Test fehlschlug.
    return "${PIPESTATUS[0]}"
}

report_failure() {   # $1 = Beschriftung, $2 = Exitcode
    echo "✗ Korpuslauf FEHLGESCHLAGEN ($1, Exit $2) – Log: /tmp/pdftools-corpus-$1.log"
    LAST_STAGING="$(ls -td "$CORPUS_ROOT"/Results/.staging-*/ 2>/dev/null | head -1)"
    if [ -n "$LAST_STAGING" ] && [ -f "$LAST_STAGING/progress.log" ]; then
        echo "  Letzte protokollierte Operationen:"
        tail -5 "$LAST_STAGING/progress.log" | sed 's/^/    /'
    fi
}

RUNNER_TEST='-only-testing:PDFToolsTests/PDFToolsCorpusRunnerTests/runConfiguredSuite()'
MERGE_TEST='-only-testing:PDFToolsTests/ShardMergeTests/mergeShardJournalsIntoSingleReport()'

if [ "$SHARDS" -le 1 ]; then
    echo "→ Führe Korpuslauf aus (ein Prozess) …"
    run_corpus "runner" "$RUNNER_TEST"
    EXIT=$?
    grep -E "Corpus Run|Total:|Blocking:|Report:|GATE FAIL" \
        /tmp/pdftools-corpus-runner.log || true
    if [ "$EXIT" -ne 0 ]; then
        report_failure "runner" "$EXIT"
        exit "$EXIT"
    fi
    echo "✓ Corpus Runner PASS"
    exit 0
fi

GROUP="$(date -u +%Y-%m-%d_%H%M%S)_${SUITE}"
export PDFTOOLS_SHARD_GROUP="$GROUP"
export TEST_RUNNER_PDFTOOLS_SHARD_GROUP="$GROUP"
echo "→ Führe Korpuslauf in $SHARDS Chargen aus (Gruppe $GROUP) …"

# Chargen laufen NEBENLÄUFIG.
#
# Sie waren immer schon unabhängig – jede bekommt ihre Dokumente reihum
# zugeteilt und schreibt ihr eigenes Journal –, liefen aber nacheinander.
# Auf zehn Kernen hiess das: neun Kerne standen still, während ein
# Korpuslauf gut eine halbe Stunde brauchte.
#
# Möglich ist das, weil Build und Test getrennt sind (siehe oben): Gebaut
# wird einmal, danach lesen alle Chargen dieselben Produkte. Nach der
# Speicherarbeit liegt der Spitzenbedarf je Lauf bei rund 450 MB, sechs
# davon sind auf dieser Maschine unkritisch.
#
# Mit PDFTOOLS_SHARD_PARALLEL=1 läuft wieder alles nacheinander – nützlich,
# wenn man einen Fehlschlag ohne Nebenlast beobachten will.
PARALLEL="${PDFTOOLS_SHARD_PARALLEL:-$SHARDS}"
SHARD_PIDS=""
for i in $(seq 1 "$SHARDS"); do
    echo "  → Charge $i von $SHARDS gestartet"
    (
        export PDFTOOLS_SHARD="$i/$SHARDS"
        export TEST_RUNNER_PDFTOOLS_SHARD="$i/$SHARDS"
        run_corpus "shard$i" "$RUNNER_TEST"
    ) &
    SHARD_PIDS="$SHARD_PIDS $i:$!"
    # Bei PARALLEL=1 sofort abwarten – dann ist die Reihenfolge wie früher.
    if [ "$PARALLEL" -le 1 ]; then wait $!; fi
done

FAILED_SHARD=""
for entry in $SHARD_PIDS; do
    i="${entry%%:*}"
    pid="${entry##*:}"
    # `wait` DARF hier fehlschlagen, ohne das Skript zu beenden.
    #
    # Als nackter Befehl unter `set -e` riss ein Fehlschlag das Skript sofort
    # ab – noch vor `EXIT=$?`. Damit wurden Journalauswertung UND
    # Zusammenführung übersprungen, also genau die Schritte, die den
    # Teilertrag eines gescheiterten Laufs retten sollen. Einmal eingetreten
    # nach 94 Minuten Rechenzeit.
    EXIT=0
    wait "$pid" || EXIT=$?
    if [ "$EXIT" -ne 0 ]; then
        report_failure "shard$i" "$EXIT"
        FAILED_SHARD="$FAILED_SHARD $i"
    fi
done

# Bericht aus den JOURNALEN, nicht aus der Ausgabe.
#
# Der Runner schreibt seine Zusammenfassung mit `print`, und das erreicht die
# xcodebuild-Ausgabe nicht – die Zeilen „Total:" und „Blocking:" standen nie
# in den Chargen-Logs. Die Journale tragen dieselben Daten verlässlich.
SHARD_DIR="$CORPUS_ROOT/Results/.shards-$GROUP"
if [ -d "$SHARD_DIR" ]; then
    python3 - "$SHARD_DIR" <<'SUMMARY'
import json, sys, glob, os, collections
rows = []
for f in sorted(glob.glob(os.path.join(sys.argv[1], "*.jsonl"))):
    n = 0
    for line in open(f):
        line = line.strip()
        if not line:
            continue
        try:
            rows.append(json.loads(line)); n += 1
        except Exception:
            pass
    print(f"    {os.path.basename(f)}: {n} Operationen")
st = collections.Counter(r.get("status") for r in rows)
print(f"  Gesamt: {len(rows)} Operationen · " +
      " · ".join(f"{k}: {v}" for k, v in sorted(st.items())))
fails = [r for r in rows if r.get("status") == "FAIL"]
byclass = collections.Counter(r.get("fixtureClass") for r in fails)
if fails:
    print("  Fehlschläge: " + ", ".join(f"{k}: {v}" for k, v in byclass.items()))
    for r in [x for x in fails if x.get("fixtureClass") != "malformed"][:5]:
        print(f"    ✗ {r.get('fixture','?')[:52]} {r.get('operation')} "
              f"{str(r.get('messages'))[:70]}")
SUMMARY
fi

# Zusammengeführt wird IMMER – auch nach einer gescheiterten Charge.
#
# Vorher brach das Skript hier ab, damit kein Teilergebnis als Gesamtergebnis
# erscheint. Die Absicht war richtig, das Mittel falsch: Eine Charge, die
# Fehlschläge FINDET, hat vollständig gearbeitet; nur eine abgestürzte hätte
# ein kurzes Journal. Genau das prüft die Zusammenführung selbst, indem sie
# fehlende Dokumente meldet. Ohne sie musste die Auswertung von Hand aus den
# Journalen geschehen – zweimal hintereinander.
if [ -n "$FAILED_SHARD" ]; then
    echo "  Chargen mit Fehlschlägen:$FAILED_SHARD – die Zusammenführung"
    echo "  läuft trotzdem und prüft die Vollständigkeit."
fi

# --- Zusammenführung --------------------------------------------------------
unset PDFTOOLS_SHARD TEST_RUNNER_PDFTOOLS_SHARD
export PDFTOOLS_MERGE_SHARDS=1
export TEST_RUNNER_PDFTOOLS_MERGE_SHARDS=1
echo "→ Führe Chargen zusammen …"
run_corpus "merge" "$MERGE_TEST"
EXIT=$?
grep -E "Chargen|Total:|Blocking:|Fehlende|Report:|GATE FAIL" \
    /tmp/pdftools-corpus-merge.log || true

if [ "$EXIT" -ne 0 ]; then
    report_failure "merge" "$EXIT"
    exit "$EXIT"
fi

echo "✓ Corpus Runner PASS"
