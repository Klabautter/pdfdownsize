#!/bin/sh
# Wird von der Xcode-Buildphase aufgerufen; fehlende Nachweise sind Buildfehler.
set -eu
ROOT="${SRCROOT:?SRCROOT fehlt}"
DEST="${BUILT_PRODUCTS_DIR:?}/${CONTENTS_FOLDER_PATH:?}/Resources/ReleaseEvidence"
mkdir -p "$DEST"
for path in \
    Vendor/qpdf/LICENSE-qpdf.txt Vendor/qpdf/NOTICE-qpdf.md \
    Vendor/qpdf/LICENSE-libjpeg-mozjpeg.md \
    Vendor/qpdf/LICENSE-zopfli.txt \
    Vendor/mozjpeg/LICENSE-mozjpeg.md Vendor/mozjpeg/NOTICE-mozjpeg.md \
    Vendor/jbig2enc/NOTICE-jbig2enc.md Vendor/libtiff/NOTICE-libtiff.md \
    Vendor/openjpeg/NOTICE-openjpeg.md Vendor/harfbuzz/NOTICE-harfbuzz.md \
    Vendor/libdeflate/NOTICE-libdeflate.md; do
    test -s "$ROOT/$path"
    cp -f "$ROOT/$path" "$DEST/"
done
# Die Abnahme schreibt Scripts/gate.sh (G1, N8) nach tmp/ (ignoriert); ohne
# sie gilt die versionierte Vorgabe (accepted = false). release-check.sh
# vergleicht den eingebetteten Commit mit HEAD – eine alte Abnahme in tmp/
# gibt also keinen anderen Stand frei.
ACCEPTANCE="$ROOT/tmp/release-acceptance.plist"
[ -f "$ACCEPTANCE" ] || ACCEPTANCE="$ROOT/Scripts/release-acceptance.plist"
/usr/bin/plutil -lint "$ACCEPTANCE" >/dev/null
cp -f "$ACCEPTANCE" "$DEST/release-acceptance.plist"
