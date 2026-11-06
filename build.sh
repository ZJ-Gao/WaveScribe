#!/bin/zsh
set -e
cd "$(dirname "$0")"
swift build -c release 2>&1 | grep -E "error|Build complete" || true
APP="WaveScribe.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp .build/release/WaveScribe "$APP/Contents/MacOS/WaveScribe"
# SwiftPM resource bundles (MLX's GPU shaders for Qwen3-ASR, and two small data bundles).
cp -R .build/release/*.bundle "$APP/Contents/Resources/"
# Punctuation runtime (sherpa-onnx C API + onnxruntime), fetched once into Vendor/ and loaded with dlopen.
SHERPA=sherpa-onnx-v2.0.1-osx-arm64-shared-no-tts-lib
if [ ! -f Vendor/sherpa-onnx/lib/libsherpa-onnx-c-api.dylib ]; then
  mkdir -p Vendor/sherpa-onnx
  curl -sSL "https://github.com/k2-fsa/sherpa-onnx/releases/download/v2.0.1/$SHERPA.tar.bz2" | tar xj -C Vendor/sherpa-onnx --strip-components 1
fi
mkdir -p "$APP/Contents/Frameworks"
cp Vendor/sherpa-onnx/lib/libsherpa-onnx-c-api.dylib Vendor/sherpa-onnx/lib/libonnxruntime.dylib "$APP/Contents/Frameworks/"
# Sparkle (in-app updates). The app is not sandboxed, so Sparkle's XPC services are not needed.
ditto .build/release/Sparkle.framework "$APP/Contents/Frameworks/Sparkle.framework"
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" "$APP/Contents/Frameworks/Sparkle.framework/XPCServices"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>${BUNDLE_ID:-com.zijiegao.voicetype}</string>
<key>CFBundleName</key><string>WaveScribe</string>
<key>CFBundleDisplayName</key><string>WaveScribe</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleExecutable</key><string>WaveScribe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>${VERSION:-0.1}</string>
<key>CFBundleVersion</key><string>${VERSION:-0.1}</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>LSUIElement</key><true/>
<key>SUFeedURL</key><string>https://raw.githubusercontent.com/ZJ-Gao/WaveScribe/main/appcast.xml</string>
<key>SUPublicEDKey</key><string>xUIaDeeiBgzklhBqk9RrfMDeZz4XQ+OY192kK/gch8k=</string>
<key>SUEnableAutomaticChecks</key><true/>
<key>SUScheduledCheckInterval</key><integer>86400</integer>
<key>NSMicrophoneUsageDescription</key><string>声波转存需要麦克风来把你的语音转成文字。</string>
</dict></plist>
PLIST
# Sign with SIGN_IDENTITY, or the first Apple Development certificate. A stable identity keeps the
# Microphone and Accessibility permissions across rebuilds.
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')}"
# With a certificate: hardened runtime. Without one (ad-hoc), skip it: its library validation would refuse
# to load the ad-hoc-signed punctuation libraries.
if [ -n "$IDENTITY" ] && [ "$IDENTITY" != "-" ]; then RUNTIME=(--options runtime --timestamp); else IDENTITY="-"; RUNTIME=(); fi
SPK="$APP/Contents/Frameworks/Sparkle.framework"
codesign --force "${RUNTIME[@]}" -s "$IDENTITY" "$SPK/Versions/B/Autoupdate" "$SPK/Versions/B/Updater.app"
codesign --force "${RUNTIME[@]}" -s "$IDENTITY" "$SPK"
codesign --force "${RUNTIME[@]}" -s "$IDENTITY" "$APP"/Contents/Frameworks/*.dylib
codesign --force "${RUNTIME[@]}" --entitlements /dev/stdin -s "$IDENTITY" "$APP" <<ENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.security.device.audio-input</key><true/>
</dict></plist>
ENT
echo "Built $APP"

# ./build.sh install  copies the app to /Applications and starts it from there.
if [ "$1" = "install" ]; then
  pkill -x WaveScribe || true
  rm -rf /Applications/WaveScribe.app
  cp -R "$APP" /Applications/WaveScribe.app
  open /Applications/WaveScribe.app
  echo "Installed to /Applications/WaveScribe.app"
fi
