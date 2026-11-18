#!/bin/bash
# Gemeinsame Grundlage der vendor-*.sh-Skripte (Masterplan G4).
#
#   - EIN Arbeitsverzeichnis, per Variable verschiebbar:
#       PDFDOWNSIZE_VENDOR_WORK (Standard: ${TMPDIR}/pdfdownsize-vendor)
#   - Jeder Download wird gegen eine fest eingetragene SHA-256 geprüft.
#     Eine abweichende Datei wird gelöscht und der Lauf bricht ab – nie wird
#     ungeprüfter Quelltext gebaut.
#   - Nur arm64. Die App läuft ausschließlich auf Apple Silicon
#     (Entscheidung 18.11.2026); Intel-Anteile werden nicht mehr gebaut.
#
# Die Prüfsummen wurden am 18.11.2026 aus den offiziellen Release-URLs
# ermittelt. Wer eine Version anhebt, trägt URL UND Prüfsumme neu ein.
#
# Wird nur per `source` eingebunden.

VENDOR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
_vendor_tmp="${TMPDIR:-/tmp}"
WORK="${PDFDOWNSIZE_VENDOR_WORK:-${_vendor_tmp%/}/pdfdownsize-vendor}"
WORK="${WORK%/}"
DOWNLOADS="$WORK/downloads"
VENDOR_ARCH="arm64"
VENDOR_DEPLOYMENT_TARGET="11.0"

CMAKE_VERSION="3.30.5"
CM="$WORK/cmake-app/CMake.app/Contents/bin/cmake"

mkdir -p "$WORK" "$DOWNLOADS"

# Bekannte Quellen: Dateiname → "URL SHA-256".
vendor_source() {
    case "$1" in
        cmake-3.30.5-macos-universal.tar.gz) echo "https://github.com/Kitware/CMake/releases/download/v3.30.5/cmake-3.30.5-macos-universal.tar.gz 3d603e507c7579b13518ef752b4ffcf3ed479fba80ee171d7d85da8153e869d0" ;;
        qpdf-12.4.0.tar.gz) echo "https://github.com/qpdf/qpdf/releases/download/v12.4.0/qpdf-12.4.0.tar.gz 2783a032f443cc886dad41aa6d5fae3dabf23dec00ee7ec2cfb27ef67ebcf529" ;;
        zopfli-ccf9f0588d4a4509cb1040310ec122243e670ee6.tar.gz) echo "https://github.com/google/zopfli/archive/ccf9f0588d4a4509cb1040310ec122243e670ee6.tar.gz 74153a2fc78235568338926d7b8ad306ae0295127aabf019103ad56137d5ffc0" ;;
        mozjpeg-4.1.1.tar.gz) echo "https://github.com/mozilla/mozjpeg/archive/refs/tags/v4.1.1.tar.gz 66b1b8d6b55d263f35f27f55acaaa3234df2a401232de99b6d099e2bb0a9d196" ;;
        tiff-4.7.2.tar.gz) echo "https://download.osgeo.org/libtiff/tiff-4.7.2.tar.gz 672bd7d10aee4606171afb864f3570b83340f6a33e2c186dc0512f7145ffdf6a" ;;
        leptonica-1.87.0.tar.gz) echo "https://github.com/DanBloomberg/leptonica/archive/refs/tags/1.87.0.tar.gz fa2b40c5caea96d1bb93a97486262aed8731b69ce25a84a6bf5d25323e33f631" ;;
        jbig2enc-23f992c92b10048064602b4d8ea29bb434752634.tar.gz) echo "https://github.com/agl/jbig2enc/archive/23f992c92b10048064602b4d8ea29bb434752634.tar.gz 5c4c9d929009e17fe31f884b179598096acde6f81462c7a1a5c0a5daeddf709f" ;;
        openjpeg-2.5.4.tar.gz) echo "https://github.com/uclouvain/openjpeg/archive/refs/tags/v2.5.4.tar.gz a695fbe19c0165f295a8531b1e4e855cd94d0875d2f88ec4b61080677e27188a" ;;
        harfbuzz-11.5.1.tar.xz) echo "https://github.com/harfbuzz/harfbuzz/releases/download/11.5.1/harfbuzz-11.5.1.tar.xz 972a60a8d274d49e70361da6920c3a73dfb0fb4387f6c6811906a47ba634d8a1" ;;
        *) return 1 ;;
    esac
}

# Lädt eine bekannte Quelle nach $DOWNLOADS (falls nicht schon da), prüft die
# Prüfsumme und entpackt nach $2 (Verzeichnis, das das Archiv anlegt), falls
# es noch nicht existiert. Gibt den Archivpfad aus.
fetch_verified() {
    local name="$1" unpack_dir="${2:-}"
    local entry url sha file actual
    entry="$(vendor_source "$name")" || { echo "FEHLER: unbekannte Quelle $name" >&2; exit 1; }
    url="${entry%% *}"; sha="${entry##* }"
    file="$DOWNLOADS/$name"
    if [ ! -f "$file" ]; then
        echo "→ Lade $name …" >&2
        curl -sSL --fail --max-time 900 -o "$file.part" "$url"
        mv "$file.part" "$file"
    fi
    actual="$(shasum -a 256 "$file" | cut -d' ' -f1)"
    if [ "$actual" != "$sha" ]; then
        rm -f "$file"
        echo "FEHLER: Prüfsumme von $name stimmt nicht." >&2
        echo "        erwartet $sha" >&2
        echo "        erhalten $actual" >&2
        exit 1
    fi
    if [ -n "$unpack_dir" ] && [ ! -d "$unpack_dir" ]; then
        tar xf "$file" -C "$WORK"
        [ -d "$unpack_dir" ] || { echo "FEHLER: $name enthält $unpack_dir nicht." >&2; exit 1; }
    fi
}

ensure_cmake() {
    if [ ! -x "$CM" ]; then
        fetch_verified "cmake-$CMAKE_VERSION-macos-universal.tar.gz" \
            "$WORK/cmake-$CMAKE_VERSION-macos-universal"
        rm -rf "$WORK/cmake-app"
        mv "$WORK/cmake-$CMAKE_VERSION-macos-universal" "$WORK/cmake-app"
    fi
}

# Bricht ab, wenn eine Datei etwas anderes als genau arm64 enthält.
require_arm64_only() {
    local f archs
    for f in "$@"; do
        archs="$(lipo -archs "$f")"
        if [ "$archs" != "$VENDOR_ARCH" ]; then
            echo "FEHLER: $f enthält '$archs' statt nur $VENDOR_ARCH." >&2
            exit 1
        fi
        echo "  ✓ $VENDOR_ARCH  $f"
    done
}

# Gemeinsames Argument --force.
parse_force() {
    FORCE=0
    local arg
    for arg in "$@"; do
        case "$arg" in
            --force) FORCE=1 ;;
            *) echo "Unbekanntes Argument: $arg (erlaubt: --force)" >&2; exit 1 ;;
        esac
    done
}
