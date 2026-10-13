# Phase 9.2 – die EINE Stelle, an der die Shell-Seite den Korpus findet.
#
# Wird von den anderen Skripten mit `source` eingebunden. Vorher trug jedes
# Skript den Vorgabepfad in seiner eigenen Zeile; acht Kopien einer
# Entscheidung, die beim Ändern siebenmal stehenbleiben.
#
# Reihenfolge – identisch zu `CorpusRootResolver` auf der Swift-Seite:
#
#     Argument  →  PDFTOOLS_CORPUS_ROOT  →  Vorgabe
#
# Aufruf:  corpus_root "${1:-}"   → setzt CORPUS_ROOT und CORPUS_ROOT_SOURCE

# Der Vorgabepfad. FEST, so vom Projektinhaber entschieden: Der Korpus liegt
# neben dem Projekt im selben Arbeitsordner.
PDFTOOLS_CORPUS_ROOT_DEFAULT="$HOME/Desktop/PDF_small/PDF_Tools-Testcorpus"

corpus_root() {
    local arg="${1:-}"
    if [ -n "$arg" ]; then
        CORPUS_ROOT="$arg";                       CORPUS_ROOT_SOURCE="argument"
    elif [ -n "${PDFTOOLS_CORPUS_ROOT:-}" ]; then
        CORPUS_ROOT="$PDFTOOLS_CORPUS_ROOT";      CORPUS_ROOT_SOURCE="env:PDFTOOLS_CORPUS_ROOT"
    else
        CORPUS_ROOT="$PDFTOOLS_CORPUS_ROOT_DEFAULT"
        CORPUS_ROOT_SOURCE="default:PDF_small/PDF_Tools-Testcorpus"
    fi
    # Tilde auflösen, damit ein `~/Korpus` nicht als Verzeichnisname endet.
    case "$CORPUS_ROOT" in "~"/*) CORPUS_ROOT="$HOME/${CORPUS_ROOT#\~/}" ;; esac
}

# Wie corpus_root, bricht aber ab, wenn die Wurzel fehlt. Ein Lauf gegen ein
# nicht vorhandenes Verzeichnis fand früher null Dokumente und meldete Erfolg.
corpus_root_required() {
    corpus_root "${1:-}"
    if [ ! -d "$CORPUS_ROOT" ]; then
        echo "FEHLER: Korpuswurzel existiert nicht: $CORPUS_ROOT" >&2
        echo "        (Quelle: $CORPUS_ROOT_SOURCE)" >&2
        echo "        PDFTOOLS_CORPUS_ROOT setzen oder den Korpus anlegen." >&2
        exit 2
    fi
}
