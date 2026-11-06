#!/bin/zsh
# Build, sign with the Developer ID certificate, notarize with Apple, package dist/WaveScribe.zip,
# write appcast.xml for in-app updates (Sparkle) and, after a confirmation, publish everything.
# Usage: ./release.sh 0.2.0 "这一版改了什么"
# Needs, once per Mac:
#   a "Developer ID Application" certificate in the keychain;
#   notarization credentials: xcrun notarytool store-credentials WaveScribe --apple-id <Apple ID> --team-id <Team ID>;
#   the Sparkle update key: .build/artifacts/sparkle/Sparkle/bin/generate_keys --account WaveScribe
set -e
cd "$(dirname "$0")"
VERSION="${1:?usage: ./release.sh 0.2.0 \"release notes\"}"
NOTES="${2:-}"
PUBLIC_REPO="ZJ-Gao/WaveScribe"
IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')
[ -n "$IDENTITY" ] || { echo "No Developer ID Application certificate in the keychain"; exit 1; }
VERSION="$VERSION" SIGN_IDENTITY="$IDENTITY" ./build.sh
mkdir -p dist
ZIP=dist/WaveScribe.zip
rm -f "$ZIP"
ditto -c -k --keepParent WaveScribe.app "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "${NOTARY_PROFILE:-WaveScribe}" --wait
# Attach the notarization ticket so the app opens without a network check, then zip again.
xcrun stapler staple WaveScribe.app
rm -f "$ZIP"
ditto -c -k --keepParent WaveScribe.app "$ZIP"
spctl -a -vv WaveScribe.app

# The update feed the app reads (SUFeedURL): one item, the latest version, signed with the Sparkle key.
SIG=$(.build/artifacts/sparkle/Sparkle/bin/sign_update --account WaveScribe "$ZIP")
cat > appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>WaveScribe</title>
    <item>
      <title>WaveScribe $VERSION</title>
      <pubDate>$(LC_ALL=C date -R)</pubDate>
      <sparkle:version>$VERSION</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <description><![CDATA[<p>${NOTES:-WaveScribe $VERSION}</p>]]></description>
      <enclosure url="https://github.com/$PUBLIC_REPO/releases/download/v$VERSION/WaveScribe.zip" $SIG type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML
echo "Ready: $ZIP and appcast.xml (version $VERSION)"

read "ok?Publish v$VERSION to GitHub (release, private repo, public repo)? [y/N] "
[ "$ok" = "y" ] || { echo "Not published. Run again when ready."; exit 0; }
# The download must exist before the public appcast points to it.
gh release create "v$VERSION" "$ZIP" --repo "$PUBLIC_REPO" --title "WaveScribe $VERSION" --notes "${NOTES:-WaveScribe $VERSION}"
git add appcast.xml
git commit -q -m "Release $VERSION"
git push -q origin main
./sync-public.sh "WaveScribe $VERSION"
echo "Published v$VERSION"
