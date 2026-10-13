#!/bin/bash
# Phase 0 – Größen-Audit: qpdf-only Baseline (optional Ghostscript /ebook)
# plus Byte-Attribution (Original + Output) je PDF.
# Aufruf: ./Scripts/size-audit.sh <ordner-mit-pdfs> [--qpdf-only|--gs|--zopfli]
# --gs führt die qpdf-only Messung ZUSÄTZLICH mit Ghostscript /ebook aus.
# --zopfli setzt QPDF_ZOPFLI=silent für die Baseline (Phase 3a) und schreibt
# die Zeile unter dem Variantennamen qpdf-zopfli (eigene Zeile, keine neue
# CSV-Spalte; Vergleich gegen die qpdf-only-Zeilen desselben Dokuments).
# Ergebnisse: bench/<name>/*.pdf|*.json, append an benchmark_results.csv.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
QPDF="$ROOT/Vendor/qpdf/qpdf"
ATTR="$ROOT/Scripts/byte-attribution.py"
CSV="$ROOT/benchmark_results.csv"
BENCH="$ROOT/bench"

MODE="--qpdf-only"
DIR=""
for arg in "$@"; do
    case "$arg" in
        --qpdf-only|--gs|--zopfli)
            MODE="$arg" ;;
        -h|--help)
            echo "Aufruf: $0 <ordner-mit-pdfs> [--qpdf-only|--gs|--zopfli]"
            exit 0 ;;
        *)
            if [ -z "$DIR" ]; then
                DIR="$arg"
            else
                echo "Fehler: unerwartetes Argument '$arg'" >&2
                exit 1
            fi ;;
    esac
done
if [ -z "$DIR" ]; then
    echo "Aufruf: $0 <ordner-mit-pdfs> [--qpdf-only|--gs|--zopfli]" >&2
    exit 1
fi
if [ ! -d "$DIR" ]; then
    echo "Fehler: Ordner nicht gefunden: $DIR" >&2
    exit 1
fi
if [ ! -x "$QPDF" ]; then
    echo "Fehler: qpdf nicht gefunden: $QPDF" >&2
    exit 1
fi

# Ghostscript nur für --gs; bei Fehlen überspringen (Hinweis).
GS=""
if [ "$MODE" = "--gs" ]; then
    for cand in /opt/homebrew/bin/gs /usr/local/bin/gs; do
        if [ -x "$cand" ]; then GS="$cand"; break; fi
    done
    if [ -z "$GS" ]; then
        GS="$(command -v gs || true)"
    fi
    if [ -z "$GS" ]; then
        echo "Hinweis: gs nicht installiert – Ghostscript-Baseline wird übersprungen." >&2
    fi
fi

shopt -s nullglob
PDFS=("$DIR"/*.pdf)
shopt -u nullglob
if [ ${#PDFS[@]} -eq 0 ]; then
    echo "Hinweis: keine PDFs in $DIR"
    exit 0
fi

# CSV-Kopfzeile: anlegen, falls Datei fehlt/leer; fremde Kopfzeile ohne
# Datenzeilen darf ersetzt werden, sonst Fehler statt kaputtes CSV.
HEADER="timestamp,document,variant,input_bytes,output_bytes,saving_pct,qpdf_ok,ssim_note,encode_ms,images_total_bytes,fonts_bytes,content_bytes,metadata_bytes,structure_bytes"
if [ ! -s "$CSV" ]; then
    echo "$HEADER" > "$CSV"
elif [ "$(head -n1 "$CSV")" != "$HEADER" ]; then
    if [ "$(wc -l < "$CSV" | tr -d ' ')" -le 1 ]; then
        echo "$HEADER" > "$CSV"
    else
        echo "Fehler: $CSV hat fremdes Format mit Datenzeilen – bitte manuell klären." >&2
        exit 1
    fi
fi

# Klassen-Bytes aus einer Attribution-JSON als TSV-Zeile.
attrib_fields() {
    python3 - "$1" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print(",".join([str(d["images"]["total"]), str(d["fonts"]),
                    str(d["content_streams"]), str(d["metadata"]),
                    str(d["structure_estimate"])]))
except Exception:
    print("\t\t\t\t")
PY
}

ts="$(date +%Y-%m-%dT%H:%M:%S)"

# --zopfli (Phase 3a): Baseline mit QPDF_ZOPFLI=silent, eigener Variantenname.
zenv=""
variant="qpdf-only"
if [ "$MODE" = "--zopfli" ]; then
    zenv="silent"
    variant="qpdf-zopfli"
fi

for f in "${PDFS[@]}"; do
    doc="$(basename "$f")"
    name="${doc%.pdf}"
    orig="$(wc -c < "$f" | tr -d ' ')"
    outdir="$BENCH/$name"
    rm -rf "$outdir"
    mkdir -p "$outdir"

    # Attribution des Originals (nur lesen, kein Schreibzugriff).
    "$ATTR" "$f" > "$outdir/original.json"
    ofields="$(attrib_fields "$outdir/original.json")"

    # qpdf-only Baseline mit Roadmap-Flags; im --zopfli-Modus mit
    # QPDF_ZOPFLI=silent (zopfli, falls verfügbar; sonst still zlib).
    t0="$(date +%s)"
    if env ${zenv:+QPDF_ZOPFLI=$zenv} "$QPDF" --object-streams=generate \
               --recompress-flate --compression-level=9 -- "$f" "$outdir/qpdf.pdf" 2>/dev/null; then
        t1="$(date +%s)"
        encode_ms=$(( (t1 - t0) * 1000 ))
        opt="$(wc -c < "$outdir/qpdf.pdf" | tr -d ' ')"
        pct="$(python3 -c "print(f'{(1-$opt/$orig)*100:.1f}')")"
        chk=0
        "$QPDF" --check "$outdir/qpdf.pdf" >/dev/null 2>&1 || chk=$?
        case "$chk" in
            0) qok="ok" ;;
            3) qok="warn" ;;
            *) qok="FAIL" ;;
        esac
        "$ATTR" "$outdir/qpdf.pdf" > "$outdir/qpdf.json"
        qfields="$(attrib_fields "$outdir/qpdf.json")"
        echo "$ts,$doc,$variant,$orig,$opt,$pct,$qok,,$encode_ms,$qfields" >> "$CSV"
        echo "$variant: $doc  $orig -> $opt Bytes (${pct} %, check=$qok, ${encode_ms} ms)"
    else
        t1="$(date +%s)"
        encode_ms=$(( (t1 - t0) * 1000 ))
        echo "$ts,$doc,$variant,$orig,0,0,FAIL,,$encode_ms,,, ,, " >> "$CSV"
        echo "$variant: $doc  FEHLGESCHLAGEN (qpdf-Aufruf)" >&2
    fi

    # Ghostscript /ebook als Referenzanker (nur messen, nicht einbauen).
    if [ "$MODE" = "--gs" ] && [ -n "$GS" ]; then
        t0="$(date +%s)"
        if "$GS" -sDEVICE=pdfwrite -dPDFSETTINGS=/ebook -dNOPAUSE -dBATCH \
                 -dQUIET -o "$outdir/gs-ebook.pdf" "$f" 2>/dev/null; then
            t1="$(date +%s)"
            gms=$(( (t1 - t0) * 1000 ))
            gopt="$(wc -c < "$outdir/gs-ebook.pdf" | tr -d ' ')"
            gpct="$(python3 -c "print(f'{(1-$gopt/$orig)*100:.1f}')")"
            "$ATTR" "$outdir/gs-ebook.pdf" > "$outdir/gs-ebook.json"
            gfields="$(attrib_fields "$outdir/gs-ebook.json")"
            echo "$ts,$doc,gs-ebook,$orig,$gopt,$gpct,n/a,,$gms,$gfields" >> "$CSV"
            echo "gs-ebook:  $doc  $orig -> $gopt Bytes (${gpct} %, ${gms} ms)"
        else
            t1="$(date +%s)"
            gms=$(( (t1 - t0) * 1000 ))
            echo "$ts,$doc,gs-ebook,$orig,0,0,FAIL,,$gms,,, ,, " >> "$CSV"
            echo "gs-ebook:  $doc  FEHLGESCHLAGEN (gs-Aufruf)" >&2
        fi
    fi
done

echo "Ergebnisse in $CSV:"
column -t -s',' "$CSV"
