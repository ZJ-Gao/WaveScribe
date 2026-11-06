#!/bin/zsh
# Build, sign with the Developer ID certificate, notarize with Apple and package dist/WaveScribe.zip
# for a GitHub Release. Usage: ./release.sh 0.1.0
# Needs a "Developer ID Application" certificate and notarization credentials saved once with
#   xcrun notarytool store-credentials WaveScribe --apple-id <Apple ID> --team-id <Team ID>
set -e
cd "$(dirname "$0")"
VERSION="${1:?usage: ./release.sh 0.1.0}"
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
echo "Ready: $ZIP (version $VERSION)"
