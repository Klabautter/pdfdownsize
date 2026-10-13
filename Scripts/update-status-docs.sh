#!/bin/bash
# Phase 11 – Statusdokumente aus Maschinendaten erzeugen.
#
# DAS PROBLEM
#
# Statusdokumente veralten unbemerkt. Beim Schreiben dieses Skripts standen
# in `PDF_CORE_BASELINE.md` und im Kopf von `ENGINEERING_PROGRESS.md` je
# „Tests: 98 grün" – tatsächlich waren es über 500. In
# `RELEASE_READINESS.md` stand „81 Tests in Debug". Drei Dokumente, drei
# verschiedene Zahlen, keine davon richtig. Genau das meint Plan 11.3:
# keine handgepflegten Testzahlen.
#
# WAS ERZEUGT WIRD
#
# Nur der Block zwischen den AUTO-STATUS-Marken. Die Fließtexte drumherum
# sind Handarbeit und bleiben unberührt – ein Generator, der ein ganzes
# Dokument überschreibt, kostet mehr, als er einbringt.
#
# QUELLEN – ausschließlich Maschinendaten
#
#   Unit-Tests   Protokoll eines `xcodebuild test`-Laufs (Argument oder frisch)
#   Korpus       report.json des jüngsten ZUSAMMENGEFÜHRTEN Laufs
#
# Eine einzelne Charge wird bewusst nicht genommen: Sie ist ein Teilergebnis.
#
# Nutzung:
#   Scripts/update-status-docs.sh [test-log] [corpus-root]
#     test-log:    Protokoll eines Testlaufs. Fehlt es, wird getestet.
set -euo pipefail

# Korpuswurzel: EINE gemeinsame Auflösung für alle Skripte (Phase 9.2).
source "$(dirname "$0")/corpus-root.sh"

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_LOG="${1:-}"
corpus_root_required "${2:-}"

if [ -z "$TEST_LOG" ]; then
    TEST_LOG="$(mktemp)"
    echo "→ Kein Protokoll übergeben – Testlauf startet …"
    (cd "$PROJECT_DIR" && xcodebuild test -scheme PDFTools \
        -destination 'platform=macOS' 2>&1 | tr '\r' '\n') > "$TEST_LOG" || true
fi

PASSED=$(grep -c "Test case .*passed" "$TEST_LOG" || true)
FAILED=$(grep -c "Test case .*failed" "$TEST_LOG" || true)

if [ "$PASSED" -eq 0 ] && [ "$FAILED" -eq 0 ]; then
    echo "FEHLER: Im Protokoll steht kein einziges Testergebnis." >&2
    echo "        ($TEST_LOG)" >&2
    echo "        Lieber gar keine Zahl als eine erfundene." >&2
    exit 3
fi

echo "→ Tests:      $PASSED bestanden, $FAILED fehlgeschlagen"
echo "→ Korpus:     $CORPUS_ROOT  ($CORPUS_ROOT_SOURCE)"

python3 - "$PROJECT_DIR" "$CORPUS_ROOT" "$PASSED" "$FAILED" <<'PY'
import json, os, sys, glob, datetime, re

project, corpus, passed, failed = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])

# Jüngster ZUSAMMENGEFÜHRTER Lauf. Einzelne Chargen sind Teilergebnisse –
# und gewinnen beim Sortieren sogar meist, weil sie ihren eigenen, späteren
# Startzeitpunkt im Namen tragen.
runs = [d for d in glob.glob(os.path.join(corpus, "Results", "*"))
        if os.path.isdir(d) and "_shard" not in os.path.basename(d)
        and os.path.exists(os.path.join(d, "report.json"))]
run = max(runs, key=os.path.getmtime) if runs else None

lines = []
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
lines.append("<!-- AUTO-STATUS:BEGIN – erzeugt von Scripts/update-status-docs.sh."
             " Von Hand geänderte Zahlen hier gehen beim nächsten Lauf verloren. -->")
lines.append("")
lines.append(f"**Stand:** {now} · automatisch erzeugt aus Testlauf und `report.json`")
lines.append("")
lines.append("| Quelle | Wert |")
lines.append("|---|---|")
lines.append(f"| Unit-Tests | **{passed} bestanden**, {failed} fehlgeschlagen |")

if run:
    d = json.load(open(os.path.join(run, "report.json")))
    ops = d.get("operations", [])
    by = {}
    for o in ops: by[o.get("status", "?")] = by.get(o.get("status", "?"), 0) + 1
    total = len(ops)
    ins  = sum(o.get("inputBytes", 0)  for o in ops if o.get("status") == "PASS")
    outs = sum(o.get("outputBytes", 0) for o in ops if o.get("status") == "PASS")
    lines.append(f"| Korpuslauf | `{d.get('meta', {}).get('runID', '?')}` |")
    lines.append(f"| Operationen | {total} |")
    for k in ("PASS", "FAIL", "SKIP"):
        n = by.get(k, 0)
        share = f"{100*n/total:.1f} %" if total else "–"
        lines.append(f"| {k} | {n} ({share}) |")
    checks = [o.get("qpdfCheck") for o in ops]
    lines.append(f"| qpdf-Prüfung PASS | {checks.count('PASS')} |")
    peaks = [o.get("peakFootprintMB") for o in ops
             if isinstance(o.get("peakFootprintMB"), int)]
    if peaks:
        lines.append(f"| Spitzenspeicher (höchster) | {max(peaks)} MB |")
else:
    lines.append("| Korpuslauf | *kein vollständiger Lauf gefunden* |")

lines.append("")
lines.append("<!-- AUTO-STATUS:END -->")
block = "\n".join(lines)

BEGIN = "<!-- AUTO-STATUS:BEGIN"
END   = "<!-- AUTO-STATUS:END -->"

for name in ("RELEASE_READINESS.md",):
    path = os.path.join(project, name)
    if not os.path.exists(path):
        print(f"   übersprungen (fehlt): {name}"); continue
    text = open(path, encoding="utf-8").read()
    if BEGIN in text and END in text:
        head = text[:text.index(BEGIN)]
        tail = text[text.index(END) + len(END):]
        text = head + block + tail
    else:
        # Erstmalig: hinter die Überschrift setzen.
        nl = text.index("\n") + 1 if "\n" in text else len(text)
        text = text[:nl] + "\n" + block + "\n" + text[nl:]
    open(path, "w", encoding="utf-8").write(text)
    print(f"   aktualisiert: {name}")
PY

echo "→ fertig"
