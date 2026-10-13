#!/bin/bash
# Masterplan Finding 18 / Schritt 9 – Real-World-Korpus auffüllen.
#
# Lädt öffentlich zugängliche PDFs in <corpus>/RealWorld/<Quelle>/.
# Ziel ist nicht bloße Anzahl, sondern PRODUZENTEN-Vielfalt: Formulare mit
# AcroForm, LaTeX-Satz, Behördenpublikationen, Scans, Tabellenlastiges.
#
# Eigenschaften:
#   - idempotent: vorhandene Dateien werden nicht erneut geladen
#   - höflich: eine Anfrage pro Sekunde, Timeout je Datei
#   - ehrlich: am Ende steht, was tatsächlich ankam, nicht was geplant war
#   - jede Datei wird auf ein gültiges PDF geprüft; HTML-Fehlerseiten fliegen raus
#
# Nutzung:
#   Scripts/fetch-corpus.sh [corpus-root]
set -uo pipefail

# Korpuswurzel: EINE gemeinsame Auflösung für alle Skripte (Phase 9.2).
source "$(dirname "$0")/corpus-root.sh"

corpus_root "${1:-}"
ROOT="$CORPUS_ROOT"
DELAY="${PDFTOOLS_FETCH_DELAY:-1}"
# 60 Sekunden reichten, solange der Korpus aus Aufsätzen und Formularen
# bestand. Seit Phase 8 stehen Dokumente bis 400 MB darin – bei 10 MB/s sind
# das über vierzig Sekunden reine Übertragung, bei schwacher Leitung ein
# Vielfaches. Ein zu knapper Ausschnitt lädt die Datei halb und wirft sie weg.
TIMEOUT="${PDFTOOLS_FETCH_TIMEOUT:-1800}"

echo "→ Korpus-Root: $ROOT"

# --- Quellenliste ------------------------------------------------------------
# Format: <Unterordner>|<Dateiname>|<URL>
#
# IRS: Formulare mit AcroForm-Feldern, Instructions mit viel Fließtext,
#      Publications mit Tabellen und Grafiken – drei sehr verschiedene
#      Erzeugerprofile aus derselben Behörde.
# arXiv: pdfTeX/LaTeX mit Subset-Fonts, Formeln, Vektorgrafiken.
# NASA NTRS: gemischte Alt- und Neubestände, teils gescannt.
SOURCES=$(cat <<'LIST'
IRS|f1040sb.pdf|https://www.irs.gov/pub/irs-pdf/f1040sb.pdf
IRS|f1040sc.pdf|https://www.irs.gov/pub/irs-pdf/f1040sc.pdf
IRS|f1040sd.pdf|https://www.irs.gov/pub/irs-pdf/f1040sd.pdf
IRS|f1040se.pdf|https://www.irs.gov/pub/irs-pdf/f1040se.pdf
IRS|f1040sf.pdf|https://www.irs.gov/pub/irs-pdf/f1040sf.pdf
IRS|f1040sh.pdf|https://www.irs.gov/pub/irs-pdf/f1040sh.pdf
IRS|f1040sj.pdf|https://www.irs.gov/pub/irs-pdf/f1040sj.pdf
IRS|f1040sr.pdf|https://www.irs.gov/pub/irs-pdf/f1040sr.pdf
IRS|f1040sse.pdf|https://www.irs.gov/pub/irs-pdf/f1040sse.pdf
IRS|f1065.pdf|https://www.irs.gov/pub/irs-pdf/f1065.pdf
IRS|f1065sb2.pdf|https://www.irs.gov/pub/irs-pdf/f1065sb2.pdf
IRS|f1065sk1.pdf|https://www.irs.gov/pub/irs-pdf/f1065sk1.pdf
IRS|f1120.pdf|https://www.irs.gov/pub/irs-pdf/f1120.pdf
IRS|f1120s.pdf|https://www.irs.gov/pub/irs-pdf/f1120s.pdf
IRS|f2106.pdf|https://www.irs.gov/pub/irs-pdf/f2106.pdf
IRS|f2210.pdf|https://www.irs.gov/pub/irs-pdf/f2210.pdf
IRS|f2441.pdf|https://www.irs.gov/pub/irs-pdf/f2441.pdf
IRS|f3800.pdf|https://www.irs.gov/pub/irs-pdf/f3800.pdf
IRS|f4562.pdf|https://www.irs.gov/pub/irs-pdf/f4562.pdf
IRS|f4797.pdf|https://www.irs.gov/pub/irs-pdf/f4797.pdf
IRS|f4868.pdf|https://www.irs.gov/pub/irs-pdf/f4868.pdf
IRS|f5329.pdf|https://www.irs.gov/pub/irs-pdf/f5329.pdf
IRS|f5695.pdf|https://www.irs.gov/pub/irs-pdf/f5695.pdf
IRS|f6251.pdf|https://www.irs.gov/pub/irs-pdf/f6251.pdf
IRS|f8283.pdf|https://www.irs.gov/pub/irs-pdf/f8283.pdf
IRS|f8582.pdf|https://www.irs.gov/pub/irs-pdf/f8582.pdf
IRS|f8606.pdf|https://www.irs.gov/pub/irs-pdf/f8606.pdf
IRS|f8829.pdf|https://www.irs.gov/pub/irs-pdf/f8829.pdf
IRS|f8863.pdf|https://www.irs.gov/pub/irs-pdf/f8863.pdf
IRS|f8949.pdf|https://www.irs.gov/pub/irs-pdf/f8949.pdf
IRS|f9465.pdf|https://www.irs.gov/pub/irs-pdf/f9465.pdf
IRS|fw2.pdf|https://www.irs.gov/pub/irs-pdf/fw2.pdf
IRS|fw4.pdf|https://www.irs.gov/pub/irs-pdf/fw4.pdf
IRS|fw9.pdf|https://www.irs.gov/pub/irs-pdf/fw9.pdf
IRS|i1040gi.pdf|https://www.irs.gov/pub/irs-pdf/i1040gi.pdf
IRS|i1040sc.pdf|https://www.irs.gov/pub/irs-pdf/i1040sc.pdf
IRS|i1065.pdf|https://www.irs.gov/pub/irs-pdf/i1065.pdf
IRS|i1120.pdf|https://www.irs.gov/pub/irs-pdf/i1120.pdf
IRS|i2106.pdf|https://www.irs.gov/pub/irs-pdf/i2106.pdf
IRS|i4562.pdf|https://www.irs.gov/pub/irs-pdf/i4562.pdf
IRS|i8949.pdf|https://www.irs.gov/pub/irs-pdf/i8949.pdf
IRS|p15.pdf|https://www.irs.gov/pub/irs-pdf/p15.pdf
IRS|p17.pdf|https://www.irs.gov/pub/irs-pdf/p17.pdf
IRS|p463.pdf|https://www.irs.gov/pub/irs-pdf/p463.pdf
IRS|p502.pdf|https://www.irs.gov/pub/irs-pdf/p502.pdf
IRS|p505.pdf|https://www.irs.gov/pub/irs-pdf/p505.pdf
IRS|p523.pdf|https://www.irs.gov/pub/irs-pdf/p523.pdf
IRS|p526.pdf|https://www.irs.gov/pub/irs-pdf/p526.pdf
IRS|p527.pdf|https://www.irs.gov/pub/irs-pdf/p527.pdf
IRS|p550.pdf|https://www.irs.gov/pub/irs-pdf/p550.pdf
IRS|p590a.pdf|https://www.irs.gov/pub/irs-pdf/p590a.pdf
IRS|p590b.pdf|https://www.irs.gov/pub/irs-pdf/p590b.pdf
IRS|p596.pdf|https://www.irs.gov/pub/irs-pdf/p596.pdf
IRS|p936.pdf|https://www.irs.gov/pub/irs-pdf/p936.pdf
IRS|p946.pdf|https://www.irs.gov/pub/irs-pdf/p946.pdf
IRS|p970.pdf|https://www.irs.gov/pub/irs-pdf/p970.pdf
IRS|p972.pdf|https://www.irs.gov/pub/irs-pdf/p972.pdf
arXiv|1706.03762.pdf|https://arxiv.org/pdf/1706.03762
arXiv|1810.04805.pdf|https://arxiv.org/pdf/1810.04805
arXiv|2005.14165.pdf|https://arxiv.org/pdf/2005.14165
arXiv|1512.03385.pdf|https://arxiv.org/pdf/1512.03385
arXiv|1409.1556.pdf|https://arxiv.org/pdf/1409.1556
arXiv|1502.03167.pdf|https://arxiv.org/pdf/1502.03167
arXiv|1412.6980.pdf|https://arxiv.org/pdf/1412.6980
arXiv|1406.2661.pdf|https://arxiv.org/pdf/1406.2661
arXiv|1312.6114.pdf|https://arxiv.org/pdf/1312.6114
arXiv|1505.04597.pdf|https://arxiv.org/pdf/1505.04597
arXiv|1703.06870.pdf|https://arxiv.org/pdf/1703.06870
arXiv|1804.02767.pdf|https://arxiv.org/pdf/1804.02767
arXiv|2010.11929.pdf|https://arxiv.org/pdf/2010.11929
arXiv|1910.10683.pdf|https://arxiv.org/pdf/1910.10683
arXiv|2103.00020.pdf|https://arxiv.org/pdf/2103.00020
arXiv|1907.11692.pdf|https://arxiv.org/pdf/1907.11692
arXiv|2006.11239.pdf|https://arxiv.org/pdf/2006.11239
arXiv|1606.04797.pdf|https://arxiv.org/pdf/1606.04797
arXiv|1611.07004.pdf|https://arxiv.org/pdf/1611.07004
arXiv|1801.04381.pdf|https://arxiv.org/pdf/1801.04381
NIST|SP.800-53r5.pdf|https://nvlpubs.nist.gov/nistpubs/SpecialPublications/NIST.SP.800-53r5.pdf
NIST|SP.800-63-3.pdf|https://nvlpubs.nist.gov/nistpubs/SpecialPublications/NIST.SP.800-63-3.pdf
NIST|SP.800-171r2.pdf|https://nvlpubs.nist.gov/nistpubs/SpecialPublications/NIST.SP.800-171r2.pdf
NIST|SP.800-207.pdf|https://nvlpubs.nist.gov/nistpubs/SpecialPublications/NIST.SP.800-207.pdf
NIST|CSWP.04162018.pdf|https://nvlpubs.nist.gov/nistpubs/CSWP/NIST.CSWP.04162018.pdf
NIST|SP.800-30r1.pdf|https://nvlpubs.nist.gov/nistpubs/Legacy/SP/nistspecialpublication800-30r1.pdf
NIST|SP.800-37r2.pdf|https://nvlpubs.nist.gov/nistpubs/SpecialPublications/NIST.SP.800-37r2.pdf
NIST|SP.800-61r2.pdf|https://nvlpubs.nist.gov/nistpubs/SpecialPublications/NIST.SP.800-61r2.pdf
# --- Phase 8: Belastungsgrössen und Erzeugervielfalt -------------------------
#
# Der Korpus war mit 388 MB zu klein, um Belastungsdateien von 500 MB aus
# unwiederholtem Material zu bauen – und er hatte kaum echte Scans. Beides
# behebt dieser Block.
#
# IPCC: ein einzelnes Dokument von 400 MB. Genau der Fall, den Phase 8 sucht:
#       Belastungsgrösse, die NICHT zusammengesetzt ist.
# Archive.org: echte Buchscans mit Farbtafeln – ein Erzeugerprofil, das im
#       Korpus vollständig fehlte (Digitalisate statt Satzsysteme).
# Census/USGS/EPA/GovInfo: Behördenpublikationen mit Tabellen, Karten und
#       Diagrammen in sehr verschiedenen Grössen.
IPCC|IPCC_AR6_WGI_FullReport.pdf|https://www.ipcc.ch/report/ar6/wg1/downloads/report/IPCC_AR6_WGI_FullReport.pdf
USGS|circ1441.pdf|https://pubs.usgs.gov/circ/1441/circ1441.pdf
Archive|audubon_birds_of_america.pdf|https://archive.org/download/birdsofamericafr01audu/birdsofamericafr01audu.pdf
Archive|byrne_euclid_1847.pdf|https://archive.org/download/firstsixbooksofe00byrn/firstsixbooksofe00byrn.pdf
Archive|darwin_origin_of_species.pdf|https://archive.org/download/onoriginofspecie00darw/onoriginofspecie00darw.pdf
Census|statab_2012.pdf|https://www2.census.gov/library/publications/2011/compendia/statab/131ed/2012-statab.pdf
EPA|ghg_inventory_2023.pdf|https://www.epa.gov/system/files/documents/2023-04/US-GHG-Inventory-2023-Main-Text.pdf
GovInfo|FR-2024-01-02.pdf|https://www.govinfo.gov/content/pkg/FR-2024-01-02/pdf/FR-2024-01-02.pdf
GovInfo|CREC-2024-01-09.pdf|https://www.govinfo.gov/content/pkg/CREC-2024-01-09/pdf/CREC-2024-01-09.pdf
NIST|NIST.HB.44-2023.pdf|https://nvlpubs.nist.gov/nistpubs/hb/2023/NIST.HB.44-2023.pdf
LIST
)

TOTAL=0
FETCHED=0
SKIPPED=0
FAILED=0
declare -a FAILED_LIST=()

while IFS='|' read -r folder name url; do
    [ -z "${folder:-}" ] && continue
    TOTAL=$((TOTAL + 1))
    dir="$ROOT/RealWorld/$folder"
    mkdir -p "$dir"
    dest="$dir/$name"

    if [ -s "$dest" ]; then
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    tmp="$dest.part"
    if curl -sSL --fail --max-time "$TIMEOUT" \
            -A "PDFTools-TestCorpus/1.0 (local test corpus)" \
            -o "$tmp" "$url" 2>/dev/null; then
        # Nur echte PDFs behalten – Fehlerseiten kommen als HTML mit Status 200.
        if head -c 5 "$tmp" | grep -q "%PDF"; then
            mv "$tmp" "$dest"
            FETCHED=$((FETCHED + 1))
            printf '  ✓ %s/%s (%s)\n' "$folder" "$name" \
                "$(du -h "$dest" | cut -f1 | tr -d ' ')"
        else
            rm -f "$tmp"
            FAILED=$((FAILED + 1))
            FAILED_LIST+=("$folder/$name (kein PDF)")
        fi
    else
        rm -f "$tmp"
        FAILED=$((FAILED + 1))
        FAILED_LIST+=("$folder/$name (Download fehlgeschlagen)")
    fi
    sleep "$DELAY"
done <<< "$SOURCES"

echo
echo "Geplant: $TOTAL · Neu geladen: $FETCHED · Bereits vorhanden: $SKIPPED · Fehlgeschlagen: $FAILED"
if [ "$FAILED" -gt 0 ]; then
    echo "Nicht geladen:"
    for item in "${FAILED_LIST[@]}"; do echo "  ✗ $item"; done
fi

echo
echo "RealWorld-Bestand:"
GRAND=0
for dir in "$ROOT"/RealWorld/*/; do
    [ -d "$dir" ] || continue
    count=$(find "$dir" -name '*.pdf' | wc -l | tr -d ' ')
    GRAND=$((GRAND + count))
    printf '  %-10s %s\n' "$(basename "$dir"):" "$count"
done
echo "  ─────────────────"
printf '  %-10s %s\n' "Gesamt:" "$GRAND"

if [ "$GRAND" -ge 220 ]; then
    echo "✓ Finding-18-Ziel erreicht (220+)"
else
    echo "→ Noch $((220 - GRAND)) PDFs bis zum Finding-18-Ziel (220+)"
fi
