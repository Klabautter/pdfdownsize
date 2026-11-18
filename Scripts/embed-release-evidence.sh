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
    Vendor/openjpeg/NOTICE-openjpeg.md Vendor/harfbuzz/NOTICE-harfbuzz.md; do
    test -s "$ROOT/$path"
    cp -f "$ROOT/$path" "$DEST/"
done
# Die Abnahme schreibt Scripts/gate.sh (G1). Ohne Gate-Lauf – jeder
# Entwicklungsbuild – trägt das Bundle ausdrücklich „nicht abgenommen“.
ACCEPTANCE="$ROOT/Scripts/release-acceptance.plist"
if [ -f "$ACCEPTANCE" ]; then
    /usr/bin/plutil -lint "$ACCEPTANCE" >/dev/null
    cp -f "$ACCEPTANCE" "$DEST/release-acceptance.plist"
else
    rm -f "$DEST/release-acceptance.plist"
    /usr/bin/plutil -create xml1 "$DEST/release-acceptance.plist"
    /usr/bin/plutil -insert accepted -bool false "$DEST/release-acceptance.plist"
    /usr/bin/plutil -insert reason -string "Scripts/gate.sh ist für diesen Build nicht gelaufen" "$DEST/release-acceptance.plist"
fi
