#!/bin/bash
# Tests aus einer Arbeitskopie AUSSERHALB des Schreibtischs fahren.
#
# Der von xcodebuild gebaute Test-Host (PDFdownsize) liest Testdateien über
# #filePath relativ zum Projekt. Liegt das Projekt auf dem Schreibtisch, fragt
# macOS bei jedem neu gebauten Host nach dem Ordnerzugriff. Aus der
# Arbeitskopie heraus gibt es keine Rückfrage.
#
#   1. Projekt (inkl. .git, tmp/, benchmark/) nach $ARBEITSKOPIE spiegeln.
#   2. xcodebuild test dort, mit allen übergebenen Argumenten.
#   3. Testartefakte (benchmark/) zurück ins Projekt kopieren – nur Dateien,
#      nichts wird im Projekt gelöscht.
#
# Der Korpus liegt ebenfalls auf dem Schreibtisch. Korpus-Tests lesen
# Kopien unter ~/Library/Developer/PDFdownsize-Korpus (siehe unten).
#
# Aufruf:  Scripts/test-arbeitskopie.sh -only-testing:PDFToolsTests/Suite …
#          Scripts/test-arbeitskopie.sh --nur-spiegeln
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARBEITSKOPIE="${PDFDOWNSIZE_ARBEITSKOPIE:-$HOME/Library/Developer/PDFdownsize-Arbeitskopie}"

mkdir -p "$ARBEITSKOPIE"
rsync -a --delete \
    --exclude 'tmp/test-build' --exclude 'tmp/release-build' \
    --exclude 'benchmark/**/outputs' --exclude '*.zip' \
    --exclude '.DS_Store' \
    "$ROOT/" "$ARBEITSKOPIE/"

# Verknüpfungen: tmp/pdfs/… und die Korpusordner bestehen zum großen Teil aus
# absoluten Symlinks in ~/Desktop/PDF_small. rsync -a kopiert sie als Links –
# der Test-Host folgte ihnen auf den Schreibtisch, und macOS fragte bei jedem
# neu gebauten Host nach dem Ordnerzugriff. Deshalb: Korpusordner nach
# $KORPUS spiegeln und JEDEN Link auf die Kopien umbiegen. Ein Link, der danach
# noch auf den Schreibtisch zeigt, bricht den Lauf ab.
QUELLE="$(dirname "$ROOT")"
KORPUS="${PDFDOWNSIZE_KORPUS:-$HOME/Library/Developer/PDFdownsize-Korpus}"
mkdir -p "$KORPUS"
for ordner in PDF_Tools-Testcorpus PDF_Corpus_System; do
    [ -d "$QUELLE/$ordner" ] && rsync -a --delete --delete-excluded --exclude '.DS_Store' --exclude '.venv' "$QUELLE/$ordner/" "$KORPUS/$ordner/"
done

umbiegen() {
    local link ziel offen=0
    while IFS= read -r -d '' link; do
        ziel="$(readlink "$link")"
        case "$ziel" in
            "$ROOT"/*) ln -sfn "$ARBEITSKOPIE/${ziel#"$ROOT"/}" "$link" ;;
            "$QUELLE"/*) ln -sfn "$KORPUS/${ziel#"$QUELLE"/}" "$link" ;;
        esac
        ziel="$(readlink "$link")"
        case "$ziel" in
            "$HOME/Desktop"*) echo "✗ Verweis auf den Schreibtisch: $link -> $ziel" >&2; offen=1 ;;
        esac
    done < <(find "$1" -type l -print0)
    return $offen
}
umbiegen "$ARBEITSKOPIE" || exit 2
umbiegen "$KORPUS" || exit 2

[ "${1:-}" = "--nur-spiegeln" ] && { echo "$ARBEITSKOPIE"; exit 0; }

# Korpus-Pfade: Ohne Angabe fallen einzelne Tests auf ~/Desktop/PDF_small/…
# zurück – schon eine Existenzprüfung dort löst bei jedem neu gebauten
# Test-Host die Schreibtisch-Abfrage aus. Deshalb zeigt JEDER Korpus-Pfad
# hier auf einen Ort außerhalb (Vorgabe: Kopien unter $KORPUS). Fehlt die
# Kopie, überspringen die Korpus-Tests sich selbst.
for pair in \
    "PDFTOOLS_CORPUS_ROOT=$KORPUS/PDF_Tools-Testcorpus" \
    "PDFTOOLS_SMOKE_CORPUS=$KORPUS/Smoke_30" \
    "PDFTOOLS_CLASSIFIER_CORPUS=$KORPUS/Smoke_30" \
    "PDFTOOLS_ESTIMATE_CORPUS=$KORPUS/Smoke_30" \
    "PDFTOOLS_MRC_CERT_CORPUS=$KORPUS/Smoke_30" \
    "PDFTOOLS_V2_CERT_CORPUS=$KORPUS/Smoke_30"; do
    name="${pair%%=*}"
    value="${!name:-${pair#*=}}"
    case "$value" in
        "$HOME/Desktop"*) echo "✗ $name zeigt auf den Schreibtisch: $value" >&2; exit 2 ;;
    esac
    export "TEST_RUNNER_$name=$value"
done

# UI-Tests (G3) brauchen die Bedienungshilfen-Freigabe für den Test-Runner –
# beim ersten Mal fragt macOS. Sie laufen nur über Scripts/ui-tests.sh
# (PDFDOWNSIZE_UI_TESTS=1), nie nebenbei in einem Unit-Lauf.
SKIP_UI=(-skip-testing:PDFToolsUITests)
[ "${PDFDOWNSIZE_UI_TESTS:-0}" = 1 ] && SKIP_UI=()

status=0
(cd "$ARBEITSKOPIE" && xcodebuild test -scheme PDFTools -destination 'platform=macOS' \
    -parallel-testing-enabled NO ${SKIP_UI[@]+"${SKIP_UI[@]}"} "$@") || status=$?

# Artefakte zurück; im Projekt wird nichts gelöscht.
rsync -a --exclude '**/outputs' "$ARBEITSKOPIE/benchmark/" "$ROOT/benchmark/"
exit $status
