#!/bin/bash
# Baut ein Release: App (Release), ZIP, Sparkle-Signatur, appcast.xml.
#
# Aufruf:  Scripts/release.sh ["Kurze Zeile, was neu ist"]
#
# Die Version kommt aus dem Xcode-Projekt (MARKETING_VERSION und
# CURRENT_PROJECT_VERSION). Vor dem Aufruf beide erhöhen – Sparkle vergleicht
# die Build-Nummer (CFBundleVersion), sie muss mit jedem Release steigen.
#
# Der private Signaturschlüssel liegt im macOS-Schlüsselbund (Konto
# "pdfdownsize", angelegt mit Sparkles generate_keys). Ohne ihn lässt sich
# kein Update signieren, das bestehende Installationen annehmen.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
NOTES="${1:-}"
REPO="Klabautter/pdfdownsize"
DERIVED="${PDFDOWNSIZE_DERIVED_DATA:-$ROOT/tmp/release-build}"

echo "→ Baue Release …"
xcodebuild build -project PDFTools.xcodeproj -scheme PDFTools \
    -configuration Release -derivedDataPath "$DERIVED" 2>&1 \
    | grep -E " error: |BUILD (SUCCEEDED|FAILED)" || true

APP="$DERIVED/Build/Products/Release/PDFdownsize.app"
[ -d "$APP" ] || { echo "Build fehlgeschlagen: $APP fehlt" >&2; exit 1; }
codesign --verify --deep --strict "$APP"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
MINOS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")"
ZIP="$ROOT/PDFdownsize-$VERSION.zip"

rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

SIGN="$(find "$DERIVED/SourcePackages/artifacts" -name sign_update -type f | head -1)"
[ -x "$SIGN" ] || { echo "sign_update nicht gefunden" >&2; exit 1; }
# Ausgabe: sparkle:edSignature="…" length="…"
SIGNATURE="$("$SIGN" --account pdfdownsize "$ZIP")"

cat > "$ROOT/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>PDFdownsize</title>
    <link>https://github.com/$REPO</link>
    <item>
      <title>Version $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MINOS</sparkle:minimumSystemVersion>
      <description><![CDATA[$NOTES]]></description>
      <enclosure url="https://github.com/$REPO/releases/download/v$VERSION/PDFdownsize-$VERSION.zip"
                 $SIGNATURE type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML

echo
echo "Version $VERSION (Build $BUILD)"
echo "ZIP:     $ZIP"
echo "SHA-256: $(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
echo
echo "Nächste Schritte:"
echo "  1. GitHub-Release v$VERSION anlegen und die ZIP anhängen."
echo "  2. appcast.xml committen und pushen – ERST DANACH sehen Nutzer das Update."
