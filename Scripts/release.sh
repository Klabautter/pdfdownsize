#!/bin/bash
# Veröffentlicht ein Release in einem Lauf: App (Release) bauen, ZIP packen,
# Sparkle-Signatur, GitHub-Release mit ZIP, appcast.xml – in der Reihenfolge,
# in der der Update-Check der Nutzer nie auf eine fehlende ZIP zeigt.
#
# Aufruf:  Scripts/release.sh [--dry-run]
#
# Ablauf:
#   1. Vorprüfung (vor dem Bauen): RELEASE_NOTES.md vorhanden, Arbeitsbaum
#      sauber, gh installiert und angemeldet, Tag v<Version> noch nicht auf
#      GitHub.
#   2. Bauen, packen, signieren, appcast.xml schreiben (noch nicht committen).
#   3. Rückfrage. Dann: main pushen (der Code, auf den das Release zeigt),
#      Tag v<Version> anlegen und pushen, GitHub-Release mit ZIP und den
#      Notizen anlegen.
#   4. ERST JETZT appcast.xml committen und pushen – ab da sehen die
#      installierten Apps das Update und finden die ZIP.
#
# RELEASE_NOTES.md: erste Zeile = ein Satz für den Update-Dialog (Sparkle),
# danach eine Leerzeile, danach die Notizen für die GitHub-Release-Seite
# (Markdown). Die Datei ist Teil des Repos und wird je Release überschrieben.
#
# Die Version kommt aus dem Xcode-Projekt (MARKETING_VERSION und
# CURRENT_PROJECT_VERSION). Vor dem Aufruf beide erhöhen – Sparkle vergleicht
# die Build-Nummer (CFBundleVersion), sie muss mit jedem Release steigen.
#
# Der private Signaturschlüssel liegt im macOS-Schlüsselbund (Konto
# "pdfdownsize", angelegt mit Sparkles generate_keys). Ohne ihn lässt sich
# kein Update signieren, das bestehende Installationen annehmen. Er verlässt
# den Mac nie – deshalb läuft das Release hier und nicht bei GitHub Actions.
#
# --dry-run: alle Schritte bis zur Signatur laufen echt (Build, ZIP, Appcast
# in den Arbeitsbaum), Push, Tag und Release werden nur angezeigt.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
REPO="Klabautter/pdfdownsize"
DERIVED="${PDFDOWNSIZE_DERIVED_DATA:-$ROOT/tmp/release-build}"
NOTES_FILE="$ROOT/RELEASE_NOTES.md"
DRY_RUN=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        *) echo "Unbekanntes Argument: $arg" >&2; echo "Aufruf: Scripts/release.sh [--dry-run]" >&2; exit 2 ;;
    esac
done

run() {
    # Führt einen Schritt aus, der nach außen wirkt – im Trockenlauf nur anzeigen.
    if [ "$DRY_RUN" = 1 ]; then
        printf '   (dry-run) %q' "$1"; shift
        for a in "$@"; do printf ' %q' "$a"; done
        echo
    else
        "$@"
    fi
}

# --- 1. Vorprüfung ----------------------------------------------------------

echo "→ Vorprüfung …"
[ -s "$NOTES_FILE" ] || {
    echo "RELEASE_NOTES.md fehlt oder ist leer. Erste Zeile: ein Satz für den" >&2
    echo "Update-Dialog, dann Leerzeile, dann die Notizen für GitHub (Markdown)." >&2
    exit 1
}
SUMMARY="$(head -n 1 "$NOTES_FILE")"
[ -n "$SUMMARY" ] || { echo "RELEASE_NOTES.md: erste Zeile ist leer." >&2; exit 1; }

if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    echo "Arbeitsbaum ist nicht sauber – erst committen, das Release zeigt auf HEAD:" >&2
    git status --short --untracked-files=no >&2
    exit 1
fi

command -v gh >/dev/null || { echo "gh fehlt: brew install gh, dann gh auth login" >&2; exit 1; }
gh auth status -h github.com >/dev/null 2>&1 || { echo "gh ist nicht angemeldet: gh auth login" >&2; exit 1; }

VERSION="$(xcodebuild -project PDFTools.xcodeproj -scheme PDFTools -configuration Release \
    -showBuildSettings 2>/dev/null | awk '/MARKETING_VERSION =/ {print $3; exit}')"
[ -n "$VERSION" ] || { echo "MARKETING_VERSION nicht lesbar" >&2; exit 1; }
TAG="v$VERSION"
# Im Trockenlauf sind diese beiden Befunde nur Hinweise, damit der Ablauf
# auch auf einem schon veröffentlichten Stand geprobt werden kann.
if git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1; then
    echo "Tag $TAG liegt schon auf GitHub – Version im Projekt erhöhen." >&2
    [ "$DRY_RUN" = 1 ] || exit 1
fi
if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
    echo "Release $TAG existiert schon auf GitHub." >&2
    [ "$DRY_RUN" = 1 ] || exit 1
fi
echo "   Version $VERSION, Tag $TAG, Notizen: $SUMMARY"

# --- 2. Bauen, packen, signieren -------------------------------------------

echo "→ Baue Release …"
# Ohne Code-Coverage und mit umgeschriebenen Quellpfaden (2026-10-22): Das
# automatisch erzeugte Schema schaltet Coverage auch für Release ein. 1.0.3
# trug dadurch 3000 Zählersymbole und über 6000 Pfade des Entwicklungsrechners
# (Benutzername) im Binary, 3 MB mehr. Die Ausgabe der App ist byte-gleich.
#
# Gestrippt werden NUR Debug-Symbole (STRIP_STYLE=debugging): Sie tragen die
# Pfade der Objektdateien. Globale Symbole müssen bleiben – die Bridge sucht
# pdfcore_remove_page_thumbs und pdfcore_minify_content_streams per dlsym im
# eigenen Binary; vollständig gestrippt fielen beide Optimierungen still weg
# (gemessen bis +7 % Ausgabegröße).
xcodebuild build -project PDFTools.xcodeproj -scheme PDFTools \
    -configuration Release -derivedDataPath "$DERIVED" \
    CLANG_COVERAGE_MAPPING=NO ENABLE_CODE_COVERAGE=NO \
    "OTHER_SWIFT_FLAGS=\$(inherited) -file-prefix-map $ROOT=." \
    "OTHER_CFLAGS=\$(inherited) -ffile-prefix-map=$ROOT=." \
    DEPLOYMENT_POSTPROCESSING=YES STRIP_INSTALLED_PRODUCT=YES \
    STRIP_STYLE=debugging 2>&1 \
    | grep -E " error: |BUILD (SUCCEEDED|FAILED)" || true

APP="$DERIVED/Build/Products/Release/PDFdownsize.app"
[ -d "$APP" ] || { echo "Build fehlgeschlagen: $APP fehlt" >&2; exit 1; }
codesign --verify --deep --strict "$APP"

# Kein Pfad des Entwicklungsrechners im veröffentlichten Bundle.
if grep -rlaF "$HOME/" "$APP" >/dev/null 2>&1; then
    echo "Das Bundle enthält Pfade unter $HOME – Release abgebrochen:" >&2
    grep -rlaF "$HOME/" "$APP" >&2
    exit 1
fi
# Per dlsym gesuchte Engine-Funktionen müssen exportiert bleiben.
# (Erst einlesen: `nm | grep -q` endet mit SIGPIPE, pipefail wertet das als Fehlschlag.)
EXPORTS="$(nm -gU "$APP/Contents/MacOS/PDFdownsize")"
for sym in pdfcore_remove_page_thumbs pdfcore_minify_content_streams; do
    grep -q "_$sym\$" <<< "$EXPORTS" || {
        echo "Symbol $sym fehlt im Binary (gestrippt?) – Release abgebrochen" >&2; exit 1; }
done

BUILT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
MINOS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")"
[ "$BUILT_VERSION" = "$VERSION" ] || {
    echo "Gebaute Version $BUILT_VERSION ≠ Projektversion $VERSION" >&2; exit 1; }
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
      <description><![CDATA[$SUMMARY]]></description>
      <enclosure url="https://github.com/$REPO/releases/download/$TAG/PDFdownsize-$VERSION.zip"
                 $SIGNATURE type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML

# Die gebaute App wird nach dem Packen entfernt: Sie steckt in der ZIP, und
# eine zweite PDFdownsize.app im Projektordner taucht sonst in Spotlight und
# Alfred neben der installierten auf. Der Rest des Build-Ordners bleibt als
# Zwischenspeicher für den nächsten Lauf.
rm -rf "$APP"

echo
echo "Version $VERSION (Build $BUILD)"
echo "ZIP:     $ZIP"
echo "SHA-256: $(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
echo

# --- 3. Veröffentlichen ----------------------------------------------------

if [ "$DRY_RUN" = 1 ]; then
    echo "Trockenlauf – diese Schritte würden folgen:"
else
    printf 'main und Tag %s pushen, Release mit ZIP anlegen, dann Appcast pushen? [j/N] ' "$TAG"
    read -r answer
    case "$answer" in
        j|J|ja|Ja|y|Y) ;;
        *) echo "Abgebrochen. ZIP und appcast.xml liegen im Arbeitsbaum (nicht committet)."; exit 0 ;;
    esac
fi

echo "→ Code pushen (das Release zeigt auf diesen Stand) …"
run git push origin main
echo "→ Tag $TAG anlegen und pushen …"
run git tag -a "$TAG" -m "PDFdownsize $VERSION"
run git push origin "$TAG"
echo "→ GitHub-Release $TAG mit ZIP anlegen …"
run gh release create "$TAG" "$ZIP" -R "$REPO" --title "PDFdownsize $VERSION" \
    --notes-file "$NOTES_FILE" --verify-tag

# --- 4. Appcast live schalten ----------------------------------------------

echo "→ appcast.xml committen und pushen – ab jetzt sehen Nutzer das Update …"
run git add appcast.xml
run git commit -m "appcast für $VERSION"
run git push origin main

echo
if [ "$DRY_RUN" = 1 ]; then
    echo "Trockenlauf beendet. Nichts gepusht, kein Tag, kein Release."
    echo "appcast.xml im Arbeitsbaum ist neu geschrieben: git checkout appcast.xml, falls unerwünscht."
else
    echo "Fertig: https://github.com/$REPO/releases/tag/$TAG"
fi
