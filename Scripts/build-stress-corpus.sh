#!/bin/bash
# Final Core Hardening, Phase 8 – Belastungskorpus aus ECHTEN Dokumenten.
#
# Der vorhandene Belastungskorpus hat viele Seiten, aber winzige Dateien:
# 1000 Seiten in 346 kB. Damit ist die Seitenzahl geprüft und sonst nichts –
# keine Bildströme, kein Plattendurchsatz, kein Speicherbedarf, keine
# Zwischendateien, keine grossen qpdf-Schreibvorgänge.
#
# WARUM ECHTE DOKUMENTE UND KEINE ERZEUGTEN
#
# Ein selbstgebautes PDF enthält genau die Strukturen, an die der Autor
# gedacht hat – es kann nicht überraschen. Genau daran ist diese Arbeit
# mehrfach vorbeigelaufen: Die Unit-Suite war grün, und der Korpus aus 285
# echten Dokumenten fand danach drei Fehler, die keine erfundene Fixture
# kannte (nachgepackte Anhänge, entartete Verweisflächen, Dokumente mit
# qpdf-Warnungen). Die Grösse entsteht deshalb aus echten Bildströmen,
# echten Schriften, echten Formularen (Plan 8.4).
#
# WARUM QPDF UND NICHT UNSER ASSEMBLER
#
# Würden wir mit PageAssemblyService zusammensetzen, prüften wir hinterher
# unseren Kompressor gegen die Ausgabe unseres eigenen Assemblers. Ein Fehler
# dort wanderte unbemerkt in den Belastungskorpus. qpdf ist das unabhängige
# Werkzeug, das im Projekt ohnehin als externer Prüfer dient.
#
# AUSWAHL NACH GEMESSENER BILDDICHTE
#
# Megabyte je Seite trennt bildlastige von textlastigen Dokumenten. Gemessen,
# nicht geraten – und damit reproduzierbar (Plan 8.3).
#
# Nutzung:
#   Scripts/build-stress-corpus.sh [corpus-root]
set -uo pipefail

# Korpuswurzel: EINE gemeinsame Auflösung für alle Skripte (Phase 9.2).
source "$(dirname "$0")/corpus-root.sh"

corpus_root "${1:-}"
CORPUS="$CORPUS_ROOT"
OUT="$CORPUS/Stress"
QPDF="$(command -v qpdf)"

[ -d "$CORPUS" ] || { echo "FEHLER: Korpus fehlt: $CORPUS"; exit 1; }
[ -n "$QPDF" ] || { echo "FEHLER: qpdf nicht gefunden"; exit 1; }
mkdir -p "$OUT"

# --- Plattenplatz (Plan 8.7) ------------------------------------------------
#
# Kein willkürliches Limit, aber auch kein Vollschreiben der Platte: Gebraucht
# werden die Dateien selbst plus Luft für die Zwischenstände einer Kompression.
NEEDED_MB=2600
AVAIL_MB=$(df -m "$OUT" | tail -1 | awk '{print $4}')
echo "Plattenplatz: ${AVAIL_MB} MB frei, ${NEEDED_MB} MB veranschlagt"
if [ "$AVAIL_MB" -lt "$NEEDED_MB" ]; then
    echo "ÜBERSPRUNGEN: zu wenig Plattenplatz."
    echo "  Das ist ein Infrastrukturbefund, kein Fehlschlag der Software."
    exit 0
fi

echo "→ Messe Bilddichte der Korpusdokumente …"
python3 - "$CORPUS" "$OUT" "$QPDF" <<'PY'
import subprocess, os, sys, glob, json

corpus, out, qpdf = sys.argv[1], sys.argv[2], sys.argv[3]

# Bilddichte je Dokument: Bytes pro Seite.
docs = []
for path in sorted(glob.glob(os.path.join(corpus, "RealWorld/**/*.pdf"),
                             recursive=True)):
    size = os.path.getsize(path)
    if size < 200 * 1024:
        continue                      # zu klein, um zur Grösse beizutragen
    try:
        pages = int(subprocess.run([qpdf, "--show-npages", path],
                    capture_output=True, text=True, timeout=30).stdout.strip())
    except Exception:
        continue
    if pages <= 0:
        continue
    docs.append({"path": path, "size": size, "pages": pages,
                 "perPage": size / pages})

docs.sort(key=lambda d: -d["perPage"])
heavy = [d for d in docs if d["perPage"] >= 0.5 * 1048576]
mixed = [d for d in docs if 0.1 * 1048576 <= d["perPage"] < 0.5 * 1048576]
light = [d for d in docs if d["perPage"] < 0.1 * 1048576]
mb = lambda b: b / 1048576
print(f"   bildlastig (>=0,5 MB/Seite): {len(heavy)} Dok, {mb(sum(d['size'] for d in heavy)):.0f} MB")
print(f"   gemischt   (0,1-0,5):        {len(mixed)} Dok, {mb(sum(d['size'] for d in mixed)):.0f} MB")
print(f"   textlastig (<0,1):           {len(light)} Dok, {mb(sum(d['size'] for d in light)):.0f} MB")

def build(name, pool, target_mb, allow_repeats):
    """Fügt Dokumente an, bis die Zielgrösse erreicht ist."""
    target = target_mb * 1048576
    chosen, total, round_ = [], 0, 0
    while total < target:
        added = False
        for d in pool:
            chosen.append(d["path"])
            total += d["size"]
            added = True
            if total >= target:
                break
        round_ += 1
        if not added or (not allow_repeats and round_ >= 1):
            break
        if round_ > 20:
            break
    return chosen, total

plan = [
    # (Datei, Vorrat, Zielgrösse MB, Wiederholungen erlaubt, Begründung)
    ("LargeImageHeavy_100MB.pdf", heavy, 100, False,
     "hochaufgeloeste Bildseiten aus echten Publikationen"),
    ("LargeMixed_250MB.pdf", heavy + mixed, 250, False,
     "Bild- und Textseiten gemischt, viele verschiedene Bild-XObjects"),
    ("LargeShared_500MB.pdf", heavy + mixed + light, 500, True,
     "gesamter Bestand mit Wiederholungen - geteilte und doppelte Ressourcen"),
]

manifest = []
for name, pool, target_mb, repeats, why in plan:
    if not pool:
        print(f"   {name}: kein Material - uebersprungen")
        continue
    files, planned = build(name, pool, target_mb, repeats)
    dest = os.path.join(out, name)
    print(f"→ {name}: {len(files)} Dokumente, geplant {planned/1048576:.0f} MB")
    r = subprocess.run([qpdf, "--empty", "--pages"] + files + ["--", dest],
                       capture_output=True, text=True)
    if r.returncode not in (0, 3) or not os.path.exists(dest):
        print(f"   FEHLGESCHLAGEN (Exit {r.returncode}): {r.stderr[:300]}")
        continue
    actual = os.path.getsize(dest)
    pages = subprocess.run([qpdf, "--show-npages", dest],
                           capture_output=True, text=True).stdout.strip()
    print(f"   fertig: {actual/1048576:.1f} MB, {pages} Seiten")
    manifest.append({
        "file": name, "bytes": actual, "pages": int(pages or 0),
        "sourceDocuments": len(files),
        "distinctSources": len(set(files)),
        "rationale": why,
    })

with open(os.path.join(out, "stress-manifest.json"), "w") as f:
    json.dump({"generatedBy": "Scripts/build-stress-corpus.sh",
               "note": "Aus echten Korpusdokumenten mit qpdf zusammengesetzt. "
                       "Nicht von Hand bearbeiten.",
               "files": manifest}, f, indent=2, ensure_ascii=False)
print("→ Manifest: Stress/stress-manifest.json")
PY
