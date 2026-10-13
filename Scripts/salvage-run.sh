#!/bin/bash
# Teilbericht aus einem ABGEBROCHENEN Korpuslauf.
#
# Ein Lauf über den vollen Korpus dauert Stunden. Endet der Testprozess
# vorzeitig, entsteht kein Report – die Rechenzeit wäre verloren. Der Runner
# journalisiert deshalb jede fertige Operation sofort nach
# `operations.jsonl`; dieses Skript wertet das Journal aus.
#
# WICHTIG: Ein Teilbericht ist KEIN bestandenes Gate. Er sagt, was bis zum
# Abbruch gemessen wurde – nicht, dass der Korpus grün ist.
#
# Nutzung:
#   Scripts/salvage-run.sh [staging-verzeichnis]
#   ohne Argument: jüngstes Staging unter <corpus>/Results/
set -uo pipefail

# Korpuswurzel: EINE gemeinsame Auflösung für alle Skripte (Phase 9.2).
source "$(dirname "$0")/corpus-root.sh"

corpus_root
ROOT="$CORPUS_ROOT"
STAGING="${1:-$(ls -td "$ROOT"/Results/.staging-*/ 2>/dev/null | head -1)}"

if [ -z "$STAGING" ] || [ ! -d "$STAGING" ]; then
    echo "Kein Staging-Verzeichnis gefunden (Korpus: $ROOT)"
    exit 1
fi

JOURNAL="$STAGING/operations.jsonl"
PROGRESS="$STAGING/progress.log"

echo "Teilbericht aus: $STAGING"
echo

if [ ! -f "$JOURNAL" ]; then
    echo "Kein Journal vorhanden – der Lauf stammt aus einer älteren Fassung."
    [ -f "$PROGRESS" ] && { echo "Letzte protokollierte Schritte:"; tail -5 "$PROGRESS"; }
    exit 1
fi

python3 - "$JOURNAL" "$PROGRESS" <<'PY'
import json, sys, collections

journal, progress = sys.argv[1], sys.argv[2]
rows = []
for line in open(journal):
    line = line.strip()
    if line:
        try:
            rows.append(json.loads(line))
        except json.JSONDecodeError:
            # Die letzte Zeile kann durch den Abbruch halb geschrieben sein.
            pass

if not rows:
    print("Journal ist leer – der Lauf brach vor der ersten Operation ab.")
    raise SystemExit(1)

status = collections.Counter(r["status"] for r in rows)
print(f"Ausgewertete Operationen: {len(rows)}")
print(f"  PASS {status['PASS']} · FAIL {status['FAIL']} · SKIP {status['SKIP']}")
print()

fails = [r for r in rows if r["status"] == "FAIL"]
# Malformed-Dokumente DÜRFEN scheitern – sie blockieren das Gate nicht.
blocking = [r for r in fails if r.get("fixtureClass") not in ("malformed",)
            and r.get("severity") in ("critical", "high")]
soft = [r for r in fails if r not in blocking]

print(f"Blockierende Fehlschläge: {len(blocking)}")
for r in blocking[:25]:
    msg = "; ".join(r.get("messages", []))[:150]
    print(f"  [{r.get('severity')}] {r['fixture']} · {r['operation']}: {msg}")
if len(blocking) > 25:
    print(f"  … und {len(blocking) - 25} weitere")

if soft:
    print()
    print(f"Nicht blockierend (Malformed/niedrige Severity): {len(soft)}")
    by_fixture = collections.Counter(r["fixture"] for r in soft)
    for fixture, count in by_fixture.most_common(8):
        print(f"  {fixture}: {count}")

print()
try:
    last = [l.strip() for l in open(progress) if l.strip()][-1]
    print(f"Letzter protokollierter Schritt: {last}")
except (OSError, IndexError):
    pass

print()
print("HINWEIS: Teilbericht eines unvollständigen Laufs – kein Gate-Ergebnis.")
PY
