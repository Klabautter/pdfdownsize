#!/bin/sh
# Wird von der Xcode-Buildphase aufgerufen; fehlende Nachweise sind Buildfehler.
set -eu
ROOT="${SRCROOT:?SRCROOT fehlt}"
DEST="${BUILT_PRODUCTS_DIR:?}/${CONTENTS_FOLDER_PATH:?}/Resources/ReleaseEvidence"
mkdir -p "$DEST"
for path in \
    Vendor/qpdf/LICENSE-qpdf.txt Vendor/qpdf/NOTICE-qpdf.md \
    Vendor/qpdf/LICENSE-libjpeg-turbo.md Vendor/qpdf/LICENSE-libjpeg-mozjpeg.md \
    Vendor/qpdf/LICENSE-zopfli.txt \
    Vendor/mozjpeg/LICENSE-mozjpeg.md Vendor/mozjpeg/NOTICE-mozjpeg.md \
    Vendor/jbig2enc/NOTICE-jbig2enc.md Vendor/libtiff/NOTICE-libtiff.md \
    Vendor/openjpeg/NOTICE-openjpeg.md Vendor/harfbuzz/NOTICE-harfbuzz.md; do
    test -s "$ROOT/$path"
    cp -f "$ROOT/$path" "$DEST/"
done
/usr/bin/plutil -lint "$ROOT/Scripts/release-acceptance.plist" >/dev/null
cp -f "$ROOT/Scripts/release-acceptance.plist" "$DEST/"
